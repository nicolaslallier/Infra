"""Nightly backup of postgres, neo4j, ntfy and openbao into the infra-backups volume.

Layout under BACKUP_DIR (/backups): <target>/<target>-<UTC stamp>.<ext>, plus
metrics/backup.prom for node-exporter's textfile collector. Heaven snapshots
the volume; this flow only has to leave consistent files there.

Containers are found by their compose labels (project infra). The one-shot
containers this flow starts (neo4j dump, ntfy tar) carry NO com.docker.compose
label: the deploy health gate counts every container of project infra and
fails on exited ones.

A dump is written to <name>.part and renamed on success, so a failed run never
leaves a file that looks like a backup.
"""

from __future__ import annotations

import os
import re
import urllib.request
import zlib
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator

from prefect import flow, get_run_logger, task
from prefect.blocks.system import Secret

BACKUP_DIR = os.environ.get("BACKUP_DIR", "/backups")
BACKUP_PG_USER = os.environ.get("BACKUP_PG_USER", "postgres")
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "3"))
METRIC = "infra_backup_last_success_timestamp_seconds"
BACKUP_STEP_TIMEOUT = int(os.environ.get("BACKUP_STEP_TIMEOUT", "900"))
BACKUP_VOLUME = "infra-backups"
NEO4J_DATABASES = ("neo4j", "system")
TARGETS = ("postgres", "neo4j", "ntfy", "openbao")


# --- pure helpers ------------------------------------------------------------


def dump_name(target: str, ext: str, now: datetime) -> str:
    return f"{target}/{target}-{now.astimezone(timezone.utc):%Y%m%dT%H%M%SZ}.{ext}"


def to_prune(names: list[str], keep: int) -> list[str]:
    # the UTC stamp sorts lexically, so the newest are last; an in-flight
    # .part is neither counted nor returned
    names = [n for n in names if not n.endswith(".part")]
    return sorted(names)[: max(len(names) - keep, 0)]


def metrics_text(last_success: dict[str, float]) -> str:
    lines = [
        f"# HELP {METRIC} Unix time of the last successful backup of a target.",
        f"# TYPE {METRIC} gauge",
    ]
    lines += [f'{METRIC}{{target="{t}"}} {v:.0f}' for t, v in sorted(last_success.items())]
    return "\n".join(lines) + "\n"


def read_metrics(path: Path) -> dict[str, float]:
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {}
    return {
        m.group(1): float(m.group(2))
        for m in re.finditer(rf'^{METRIC}\{{target="([^"]+)"\}} (\S+)$', text, re.M)
    }


def write_atomic(path: Path, chunks: Iterable[bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(path.suffix + ".part")
    try:
        with open(part, "wb") as f:
            for chunk in chunks:
                f.write(chunk)
        part.rename(path)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


# --- docker ------------------------------------------------------------------


def _docker():
    import docker  # lazy: the image installs it via EXTRA_PIP_PACKAGES

    return docker.from_env()


def _container(client, service: str):
    found = client.containers.list(
        filters={
            "label": [
                "com.docker.compose.project=infra",
                f"com.docker.compose.service={service}",
            ]
        }
    )
    if not found:
        raise RuntimeError(f"no running {service} container")
    return found[0]


def _volume(container, destination: str) -> str:
    for m in container.attrs.get("Mounts", []):
        if m.get("Destination") == destination and m.get("Name"):
            return m["Name"]
    raise RuntimeError(f"{container.attrs.get('Name', '?')}: no named volume at {destination}")


def _run_once(client, image, command, **kw) -> None:
    """Run a one-shot container to completion, with a timeout.

    No labels (see module doc). Detached so a hung process cannot block
    forever; always removed, on success, failure and timeout.
    """
    c = client.containers.run(image, command, detach=True, **kw)
    try:
        try:
            res = c.wait(timeout=BACKUP_STEP_TIMEOUT)
        except Exception as e:  # docker-py raises requests' ReadTimeout/ConnectionError
            raise RuntimeError(f"{image} {command[0]} failed waiting for exit (limit {BACKUP_STEP_TIMEOUT}s): {e}") from e
        if res.get("StatusCode", 1) != 0:
            try:
                tail = c.logs(tail=20).decode(errors="replace")[-500:]
            except Exception:
                tail = "(no logs)"
            raise RuntimeError(f"{image} {command[0]} exited {res.get('StatusCode')}: {tail}")
    finally:
        try:
            c.remove(force=True)
        except Exception:
            pass  # already gone


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _gzip(chunks: Iterable[bytes]) -> Iterator[bytes]:
    z = zlib.compressobj(wbits=31)  # gzip container
    for c in chunks:
        yield z.compress(c)
    yield z.flush()


def _gzip_checked(chunks: Iterable[bytes]) -> Iterator[bytes]:
    # a body that ends cleanly but early is still a broken snapshot; raising
    # inside the generator makes write_atomic drop the .part
    d = zlib.decompressobj(wbits=31)
    for c in chunks:
        d.decompress(c)
        yield c
    if not d.eof:
        raise RuntimeError("openbao snapshot: truncated gzip stream")


# --- tasks -------------------------------------------------------------------


@task(name="dump-postgres")
def dump_postgres() -> Path:
    client = _docker()
    container = _container(client, "postgres")
    api = client.api
    exec_id = api.exec_create(
        container.id, ["pg_dumpall", "-U", BACKUP_PG_USER], user="postgres"
    )["Id"]
    stderr_tail: deque[bytes] = deque(maxlen=20)

    def sql() -> Iterator[bytes]:
        for out, err in api.exec_start(exec_id, stream=True, demux=True):
            if err:
                stderr_tail.append(err)
            if out:
                yield out
        # raised inside the generator so write_atomic removes the .part
        code = api.exec_inspect(exec_id)["ExitCode"]
        if code != 0:
            raise RuntimeError(
                f"pg_dumpall exited {code}: {b''.join(stderr_tail).decode(errors='replace')[-500:]}"
            )

    path = Path(BACKUP_DIR) / dump_name("postgres", "sql.gz", _now())
    write_atomic(path, _gzip(sql()))
    return path


@task(name="dump-neo4j")
def dump_neo4j() -> Path:
    # Neo4j Community has no online dump: stop it, dump, start it again (about
    # a minute of outage). start() is in finally so a failed dump never leaves
    # the graph down.
    client = _docker()
    container = _container(client, "neo4j")
    image = container.attrs["Config"]["Image"]
    data_volume = _volume(container, "/data")
    base = Path(BACKUP_DIR)
    tmp = base / "neo4j" / ".tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    for stale in tmp.iterdir():  # leftovers of an interrupted run
        stale.unlink()
    now = _now()
    try:
        container.stop(timeout=60)
        for db in NEO4J_DATABASES:
            _run_once(
                client,
                image,
                ["database", "dump", db, "--to-path=/backups/neo4j/.tmp"],
                # bypass the image entrypoint, which drops to the neo4j user;
                # that user cannot write the root-owned backup volume
                entrypoint=["neo4j-admin"],
                user="root",
                volumes={
                    # Writable on purpose: neo4j-admin writes
                    # /data/databases/<db>/database_lock even for a dump, and
                    # fails with "Could not write to ... database_lock" on ro.
                    data_volume: {"bind": "/data"},
                    BACKUP_VOLUME: {"bind": "/backups"},
                },
            )
    finally:
        container.start()
    if not NEO4J_DATABASES:
        raise RuntimeError("no neo4j database to dump")
    for db in NEO4J_DATABASES:
        target = "neo4j" if db == "neo4j" else "neo4j-system"
        final = base / dump_name(target, "dump", now)
        final.parent.mkdir(parents=True, exist_ok=True)
        (tmp / f"{db}.dump").rename(final)
    return base / dump_name("neo4j", "dump", now)


@task(name="dump-ntfy")
def dump_ntfy() -> Path:
    client = _docker()
    container = _container(client, "ntfy")
    src = _volume(container, "/var/lib/ntfy")
    base = Path(BACKUP_DIR)
    (base / "ntfy").mkdir(parents=True, exist_ok=True)
    # ponytail: tars ntfy's live SQLite files while ntfy may be writing, so a
    # torn copy is possible; upgrade: `sqlite3 .backup` or pause ntfy for the tar.
    _run_once(
        client,
        "alpine:3",
        ["tar", "czf", "/backups/ntfy/.tmp.tgz", "-C", "/src", "."],
        volumes={
            src: {"bind": "/src", "mode": "ro"},
            BACKUP_VOLUME: {"bind": "/backups"},
        },
    )
    final = base / dump_name("ntfy", "tgz", _now())
    (base / "ntfy" / ".tmp.tgz").rename(final)
    return final


@task(name="dump-openbao")
def dump_openbao() -> Path:
    # Scoped periodic token (policy `backup`: snapshot read + renew-self only),
    # minted by `make vault-backup-token`. Renewed first so it never lapses.
    addr = os.environ.get("BACKUP_BAO_ADDR", "http://openbao:8200")
    headers = {"X-Vault-Token": Secret.load("openbao-backup-token").get()}

    def call(method: str, path: str):
        req = urllib.request.Request(f"{addr}/v1/{path}", method=method, headers=headers)
        return urllib.request.urlopen(req, timeout=BACKUP_STEP_TIMEOUT)

    with call("POST", "auth/token/renew-self"):
        pass
    path = Path(BACKUP_DIR) / dump_name("openbao", "snap", _now())
    with call("GET", "sys/storage/raft/snapshot") as r:  # non-2xx raises HTTPError
        write_atomic(path, _gzip_checked(iter(lambda: r.read(1 << 20), b"")))
    return path


# --- flow --------------------------------------------------------------------


def _prune(target: str) -> None:
    d = Path(BACKUP_DIR) / target
    if not d.is_dir():
        return
    files = [p.name for p in d.iterdir() if p.is_file() and p.name.startswith(f"{target}-") and p.suffix != ".part"]
    for name in to_prune(files, BACKUP_KEEP):
        (d / name).unlink()


@flow(name="backup", log_prints=True)
def backup() -> dict[str, str]:
    log = get_run_logger()
    prom = Path(BACKUP_DIR) / "metrics" / "backup.prom"
    # a failed target keeps its previous time; a never-succeeded one exports 0,
    # so `Backup stale` fires for it
    last = {t: 0.0 for t in TARGETS} | read_metrics(prom)
    results: dict[str, str] = {}
    failed = []
    for target, fn in zip(TARGETS, (dump_postgres, dump_neo4j, dump_ntfy, dump_openbao)):
        try:
            path = fn()
            last[target] = _now().timestamp()
            results[target] = str(path)
        except Exception as e:  # one failing target must not skip the others
            log.error("backup of %s failed: %s", target, e)
            results[target] = f"failed: {e}"
            failed.append(target)
    for target in (*TARGETS, "neo4j-system"):
        _prune(target)
    write_atomic(prom, [metrics_text(last).encode()])
    if failed:
        raise RuntimeError(f"backup failed for: {', '.join(failed)}")
    return results
