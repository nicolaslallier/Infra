"""Plain-assert checks that pr_validation never runs a PR's own scripts with
the flow's privileges (it holds the Docker socket and the flow secrets).

Run from the repo root:
  uv run --no-project --python 3.12 --with prefect==3.8.7 --with fastapi \
    --with docker --with pyyaml python prefect/flows/test_pr_validation.py
"""

from __future__ import annotations

import base64
import io
import os
import tarfile
import subprocess
import tempfile

import pr_validation as pv


def _assert_sandboxed(kw, workspace):
    assert kw["network_mode"] == "none", kw
    assert not kw.get("environment"), "no env passthrough"
    assert "@sha256:" in kw["image"], "image must be pinned"
    assert kw["read_only"] is True
    assert kw["cap_drop"] == ["ALL"]
    assert "no-new-privileges" in " ".join(kw["security_opt"])
    assert kw["mem_limit"] and kw["pids_limit"] and kw["nano_cpus"]
    assert kw["timeout"] <= 300
    assert kw["tmpfs"], "writes go to a tmpfs"
    assert not any("docker.sock" in v for v in kw["volumes"]), kw["volumes"]
    assert kw["volumes"][workspace]["mode"] == "ro", "the clone is read-only"
    assert all(v["mode"] == "ro" for v in kw["volumes"].values()), "no writable host mount"


def test_sandbox_spec():
    kw = pv._sandbox_kwargs("/tmp/infra-ci/pr-1", ["true"])
    _assert_sandboxed(kw, "/tmp/infra-ci/pr-1")


def test_pr_scripts_only_run_in_sandbox():
    calls = []

    def boom(*a, **k):
        raise AssertionError(f"PR script ran in-process: {a}")

    def fake(**kw):
        calls.append(kw)
        if kw["image"] == pv.IMG_SANDBOX and "ci-fake-env" in " ".join(kw["command"]):
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as t:
                data = b"A=1\n"
                info = tarfile.TarInfo(".env")
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
            return 0, "log\n%s\n%s\n%s\n" % (pv._TAR_BEGIN, base64.b64encode(buf.getvalue()).decode(), pv._TAR_END)
        return 0, "ok"

    real_run, real_docker = subprocess.run, pv._docker_run
    subprocess.run, pv._docker_run = boom, fake
    try:
        with tempfile.TemporaryDirectory() as ws:
            # A hostile clone: .env is a symlink out of the workspace.
            target = os.path.join(ws, "..", "victim")
            os.symlink(target, os.path.join(ws, ".env"))
            results = pv._run_all(ws)
            assert not os.path.lexists(target), "wrote through a PR symlink"
            assert os.path.isfile(os.path.join(ws, ".env"))
    finally:
        subprocess.run, pv._docker_run = real_run, real_docker

    sandboxed = [c for c in calls if c["image"] == pv.IMG_SANDBOX]
    text = [" ".join(c["command"]) for c in sandboxed]
    assert any("ci-fake-env.sh" in t for t in text)
    assert any("check-env.sh" in t for t in text)
    for c in sandboxed:
        ro = next(p for p, v in c["volumes"].items() if v["mode"] == "ro")
        _assert_sandboxed(c, ro)
    assert not any(c["image"] != pv.IMG_SANDBOX and "docker.sock" in str(c["volumes"]) for c in calls), "compose check needs no socket"
    assert [r["name"] for r in results][:2] == ["prepare workspace", "check-env"]


if __name__ == "__main__":
    test_sandbox_spec()
    print("ok test_sandbox_spec")
    test_pr_scripts_only_run_in_sandbox()
    print("ok test_pr_scripts_only_run_in_sandbox")
