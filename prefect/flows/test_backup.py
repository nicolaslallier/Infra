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


class FakeOneShot:
    def __init__(self, wait_exc=None):
        self.wait_exc = wait_exc
        self.removed = 0

    def wait(self, timeout=None):
        assert timeout
        if self.wait_exc:
            raise self.wait_exc
        return {"StatusCode": 0}

    def remove(self, force=False):
        self.removed += 1


class FakeClient:
    def __init__(self, containers, run=None):
        self._c = containers
        self.run_calls = []
        self.oneshots = []
        self.wait_exc = None
        self._run = run
        self.containers = self

    def list(self, filters=None, **kw):
        svc = [f for f in filters["label"] if "service=" in f][0].split("=")[-1]
        return [self._c[svc]]

    def run(self, image, command, **kw):
        self.run_calls.append((image, command, kw))
        if self._run:
            self._run()
        o = FakeOneShot(self.wait_exc)
        self.oneshots.append(o)
        return o


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
    assert "some_neo4j_vol" in kw["volumes"] and kw["detach"] is True
    assert "mode" not in kw["volumes"]["some_neo4j_vol"]  # must stay writable (database_lock)
    assert all(o.removed == 1 for o in client.oneshots)
    for _, _, kw in client.run_calls:
        _no_compose_labels(kw)
    assert c.started == 1


def test_neo4j_timeout_restarts_and_removes():
    c = FakeContainer(_neo4j_attrs())
    client = FakeClient({"neo4j": c})
    client.wait_exc = TimeoutError("read timed out")
    backup._docker = lambda: client
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d
        try:
            backup.dump_neo4j.fn()
        except RuntimeError as e:
            assert "timed out" in str(e)
        else:
            raise AssertionError("expected RuntimeError")
    assert c.started == 1 and [o.removed for o in client.oneshots] == [1]


def test_neo4j_no_databases_raises():
    c = FakeContainer(_neo4j_attrs())
    client = FakeClient({"neo4j": c})
    backup._docker = lambda: client
    old = backup.NEO4J_DATABASES
    backup.NEO4J_DATABASES = ()
    try:
        with tempfile.TemporaryDirectory() as d:
            backup.BACKUP_DIR = d
            try:
                backup.dump_neo4j.fn()
            except RuntimeError:
                pass
            else:
                raise AssertionError("expected RuntimeError")
    finally:
        backup.NEO4J_DATABASES = old
    assert c.started == 1


def test_to_prune_ignores_part():
    names = [f"t/t-2026110{d}T013000Z.x" for d in (1, 2, 3)] + ["t/t-20261104T013000Z.x.part"]
    out = backup.to_prune(names, 2)
    assert out == ["t/t-20261101T013000Z.x"], out


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


import gzip as _gzip_mod

_BODY = _gzip_mod.compress(b"snapbytes")


class _Secret:
    @staticmethod
    def load(name):
        assert name == "openbao-backup-token"
        return type("S", (), {"get": lambda self: "tok"})()


def _fake_urlopen(calls, fail_on=None):
    import io
    import urllib.error

    def urlopen(req, timeout=None):
        assert timeout, "every request needs a timeout"
        calls.append((req.get_method(), req.full_url, req.get_header("X-vault-token")))
        if fail_on and req.get_method() == fail_on:
            raise urllib.error.HTTPError(req.full_url, 403, "denied", {}, None)
        return io.BytesIO(_BODY)

    return urlopen


def test_openbao_renews_then_snapshots():
    import urllib.request

    calls = []
    backup.Secret = _Secret
    urllib.request.urlopen = _fake_urlopen(calls)
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d
        out = backup.dump_openbao.fn()
        assert out.suffix == ".snap" and out.read_bytes() == _BODY
    assert calls == [
        ("POST", "http://openbao:8200/v1/auth/token/renew-self", "tok"),
        ("GET", "http://openbao:8200/v1/sys/storage/raft/snapshot", "tok"),
    ], calls


def test_openbao_http_error_leaves_no_file():
    import urllib.error
    import urllib.request

    backup.Secret = _Secret
    urllib.request.urlopen = _fake_urlopen([], fail_on="GET")
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d
        try:
            backup.dump_openbao.fn()
            raise AssertionError("should have raised")
        except urllib.error.HTTPError:
            pass
        assert not list((Path(d) / "openbao").glob("*"))


def test_openbao_truncated_gzip_rejected():
    global _BODY
    import urllib.request

    good = _BODY
    backup.Secret = _Secret
    try:
        _BODY = good[:-6]
        urllib.request.urlopen = _fake_urlopen([])
        with tempfile.TemporaryDirectory() as d:
            backup.BACKUP_DIR = d
            try:
                backup.dump_openbao.fn()
                raise AssertionError("should have raised")
            except RuntimeError:
                pass
            assert not list((Path(d) / "openbao").glob("*"))
    finally:
        _BODY = good


def test_nonzero_exit_includes_logs():
    class Failing(FakeOneShot):
        def wait(self, timeout=None):
            return {"StatusCode": 3}

        def logs(self, tail=None):
            return b"boom: disk full"

    client = FakeClient({})
    client.run = lambda image, command, **kw: Failing()
    try:
        backup._run_once(client, "img", ["x"])
        raise AssertionError("should have raised")
    except RuntimeError as e:
        assert "boom: disk full" in str(e) and "exited 3" in str(e)


def test_never_succeeded_target_exports_zero():
    with tempfile.TemporaryDirectory() as d:
        backup.BACKUP_DIR = d

        def fail():
            raise RuntimeError("x")

        saved = (backup.dump_postgres, backup.dump_neo4j, backup.dump_ntfy, backup.dump_openbao)
        import logging

        backup.get_run_logger = lambda: logging.getLogger('t')
        backup.dump_postgres = backup.dump_neo4j = backup.dump_ntfy = backup.dump_openbao = fail
        try:
            try:
                backup.backup.fn()
                raise AssertionError('flow should fail')
            except RuntimeError as e:
                assert 'backup failed for' in str(e), e
        finally:
            backup.dump_postgres, backup.dump_neo4j, backup.dump_ntfy, backup.dump_openbao = saved
        m = backup.read_metrics(Path(d) / "metrics" / "backup.prom")
        assert m == {t: 0.0 for t in backup.TARGETS}, m


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
