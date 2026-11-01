"""Plain-assert checks for backup.py. Fakes only: no Docker daemon is touched.

Run from the repo root:
  uv run --no-project --python 3.12 --with prefect==3.8.7 --with docker \
    python prefect/flows/test_backup.py
"""

from __future__ import annotations

import tempfile
from datetime import datetime, timezone
from pathlib import Path

import backup

UTC = timezone.utc


def test_dump_name():
    now = datetime(2026, 11, 1, 6, 30, tzinfo=UTC)
    assert backup.dump_name("postgres", "sql.gz", now) == "postgres/postgres-20261101T063000Z.sql.gz"


def test_to_prune_keeps_newest():
    names = [f"postgres/postgres-2026110{d}T013000Z.sql.gz" for d in (3, 1, 5, 2, 4)]
    assert sorted(backup.to_prune(names, 3)) == sorted(
        [f"postgres/postgres-2026110{d}T013000Z.sql.gz" for d in (1, 2)]
    )


def test_metrics_text():
    text = backup.metrics_text({"postgres": 1700000000.0})
    assert 'infra_backup_last_success_timestamp_seconds{target="postgres"} 1700000000' in text
    assert "# TYPE infra_backup_last_success_timestamp_seconds gauge" in text
    assert text.endswith("\n")


def test_failed_dump_leaves_no_file():
    def gen():
        yield b"abc"
        raise RuntimeError("boom")

    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.gz"
        try:
            backup.write_atomic(p, gen())
        except RuntimeError:
            pass
        else:
            raise AssertionError("expected RuntimeError")
        assert not p.exists() and not Path(str(p) + ".part").exists()


def test_write_atomic_success():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "sub" / "x.gz"
        backup.write_atomic(p, [b"a", b"b"])
        assert p.read_bytes() == b"ab" and not Path(str(p) + ".part").exists()


def test_previous_metrics_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "backup.prom"
        assert backup.read_metrics(p) == {}
        p.write_text(backup.metrics_text({"neo4j": 5.0, "ntfy": 7.0}))
        assert backup.read_metrics(p) == {"neo4j": 5.0, "ntfy": 7.0}


class FakeContainer:
    id = "cid"

    def __init__(self, attrs=None):
        self.attrs = attrs or {}
        self.started = 0
        self.stopped = 0

    def stop(self, **kw):
        self.stopped += 1

    def start(self):
        self.started += 1


class FakeClient:
    def __init__(self, containers, run=None):
        self._c = containers
        self.run_calls = []
        self._run = run
        self.containers = self

    def list(self, filters=None, **kw):
        svc = [f for f in filters["label"] if "service=" in f][0].split("=")[-1]
        return [self._c[svc]]

    def run(self, image, command, **kw):
        self.run_calls.append((image, command, kw))
        if self._run:
            self._run()


def _neo4j_attrs():
    return {
        "Config": {"Image": "neo4j:2026.01-community"},
        "Mounts": [{"Destination": "/data", "Name": "some_neo4j_vol"}],
    }


def _no_compose_labels(kw):
    assert "com.docker.compose" not in str(kw.get("labels", {}))


def test_neo4j_restarted_on_failure():
    c = FakeContainer(_neo4j_attrs())

    def boom():
        raise RuntimeError("dump failed")

    client = FakeClient({"neo4j": c}, run=boom)
    backup._docker = lambda: client
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d
        try:
            backup.dump_neo4j.fn()
        except RuntimeError:
            pass
        else:
            raise AssertionError("expected RuntimeError")
    assert c.stopped == 1 and c.started == 1
    _no_compose_labels(client.run_calls[0][2])


def test_neo4j_success_names_volume_from_container():
    c = FakeContainer(_neo4j_attrs())
    client = FakeClient({"neo4j": c})
    backup._docker = lambda: client
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d
        calls = []

        def fake_dump():
            # what neo4j-admin leaves behind: <db>.dump in the --to-path dir
            db = client.run_calls[-1][1][2]
            calls.append(db)
            (Path(d) / "neo4j" / ".tmp" / f"{db}.dump").write_bytes(b"x")

        client._run = fake_dump
        out = backup.dump_neo4j.fn()
        assert calls == ["neo4j", "system"]
        assert out.exists() and out.name.startswith("neo4j-") and out.suffix == ".dump"
        assert list((Path(d) / "neo4j-system").glob("neo4j-system-*.dump"))
        assert not list((Path(d) / "neo4j" / ".tmp").iterdir())
    image, _, kw = client.run_calls[0]
    assert image == "neo4j:2026.01-community"
    assert "some_neo4j_vol" in kw["volumes"] and kw["remove"] is True
    for _, _, kw in client.run_calls:
        _no_compose_labels(kw)
    assert c.started == 1


def test_ntfy_uses_mount_volume_and_no_labels():
    c = FakeContainer({"Mounts": [{"Destination": "/var/lib/ntfy", "Name": "ntfy_vol"}]})
    client = FakeClient({"ntfy": c})
    backup._docker = lambda: client
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d

        def fake_tar():
            (Path(d) / "ntfy" / ".tmp.tgz").write_bytes(b"x")

        client._run = fake_tar
        out = backup.dump_ntfy.fn()
        assert out.exists() and out.name.startswith("ntfy-") and out.name.endswith(".tgz")
    image, _, kw = client.run_calls[0]
    assert image == "alpine:3" and kw["volumes"]["ntfy_vol"]["mode"] == "ro"
    _no_compose_labels(kw)


class FakeApi:
    def __init__(self, code):
        self.code = code

    def exec_create(self, cid, cmd, user=None):
        assert cmd[0] == "pg_dumpall" and user == "postgres"
        return {"Id": "eid"}

    def exec_start(self, eid, stream=False, demux=False):
        assert stream and demux
        return iter([(b"-- dump\n", None), (None, b"warn")])

    def exec_inspect(self, eid):
        return {"ExitCode": self.code}


def FakeExecClient(c, code):
    client = FakeClient({"postgres": c})
    client.api = FakeApi(code)
    return client


def test_postgres_nonzero_exit_leaves_no_file():
    for code, ok in ((0, True), (1, False)):
        backup._docker = lambda code=code: FakeExecClient(FakeContainer(), code)
        with tempfile.TemporaryDirectory() as d:
            backup.BACKUP_DIR = d
            try:
                out = backup.dump_postgres.fn()
                assert ok and out.exists()
            except RuntimeError:
                assert not ok
                assert not list((Path(d) / "postgres").glob("*.gz*"))


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
