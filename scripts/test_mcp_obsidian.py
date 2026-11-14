"""Tests for mcp/obsidian (notes.py, server.py) against a stub S3 (needs boto3 and mcp).

Run: uv run -q --no-project --with pyyaml --with boto3==<pin> --with mcp==<pin> python scripts/test_mcp_obsidian.py
"""
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "mcp", "obsidian"))
import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402

import notes  # noqa: E402

BUCKET = "obsidian"
TOKEN = "t0ken-for-tests"
DATA = {
    "Inbox/a.md": b"# a\nrendez-vous avec Marie Tremblay demain\n",
    "Projects/plan.md": b"# plan\nacheter du lait\n",
    "Projects/deep/x.md": b"# x\nrien\n",
    "Journal/2026-01-01.md": b"journal: " + b"mot " * 200 + b"MARIE a appele\n",
    ".obsidian/app.json": b"{}",
    ".obsidian/plugins/x/notes.md": b"plugin notes: Marie\n",
    "photo.png": b"\x89PNG....",
    "big.md": b"x" * (2 * 1024 * 1024),
}


class StubS3(ThreadingHTTPServer):
    """ListObjectsV2 and GetObject, no signature check; counts GETs of objects."""

    def __init__(self):
        self.gets = 0
        stub = self

        class H(BaseHTTPRequestHandler):
            def do_GET(h):  # noqa: N805
                u = urlsplit(h.path)
                q = parse_qs(u.query)
                parts = unquote(u.path).lstrip("/").split("/", 1)
                if len(parts) == 1 or not parts[1]:  # list
                    prefix = q.get("prefix", [""])[0]
                    keys = sorted(k for k in DATA if k.startswith(prefix))
                    start = int(q.get("continuation-token", ["0"])[0])
                    page = keys[start:start + int(q.get("max-keys", ["1000"])[0])]
                    trunc = start + len(page) < len(keys)
                    body = (
                        '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>'
                        f"<Name>{BUCKET}</Name><Prefix>{escape(prefix)}</Prefix><KeyCount>{len(page)}</KeyCount>"
                        f"<MaxKeys>1000</MaxKeys><IsTruncated>{'true' if trunc else 'false'}</IsTruncated>"
                        + (f"<NextContinuationToken>{start + len(page)}</NextContinuationToken>" if trunc else "")
                        + "".join(f"<Contents><Key>{escape(k)}</Key><Size>{len(DATA[k])}</Size>"
                                  '<LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>"e"</ETag>'
                                  "<StorageClass>STANDARD</StorageClass></Contents>" for k in page)
                        + "</ListBucketResult>"
                    ).encode()
                    h.send_response(200)
                    h.send_header("Content-Type", "application/xml")
                else:
                    key = parts[1]
                    if key not in DATA:
                        h.send_response(404)
                        h.send_header("Content-Length", "0")
                        h.end_headers()
                        return
                    stub.gets += 1
                    body = DATA[key]
                    h.send_response(200)
                    h.send_header("Content-Type", "application/octet-stream")
                h.send_header("Content-Length", str(len(body)))
                h.end_headers()
                try:
                    h.wfile.write(body)
                except BrokenPipeError:  # the client refused the body (a note over the size cap)
                    pass

            def log_message(h, *args):  # noqa: N805
                pass

        super().__init__(("127.0.0.1", 0), H)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"


STUB = StubS3()


def s3():
    return boto3.client("s3", endpoint_url=STUB.url, aws_access_key_id="k", aws_secret_access_key="s",
                        region_name="us-east-1", config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1}))


def raises(fn, exc=ValueError):
    try:
        fn()
    except exc:
        return
    raise AssertionError(f"{exc.__name__} not raised")


def test_normalize_rejects_parent_traversal_and_absolute_paths():
    for bad in ("../x.md", "/abs.md", "a/../../x.md", "a/..", "", "a\\b.md", "a/\x00.md", "..", "\\x.md"):
        raises(lambda: notes.normalize_path(bad))


def test_normalize_keeps_ordinary_paths():
    assert notes.normalize_path("Inbox/a.md") == "Inbox/a.md"
    assert notes.normalize_path("./Inbox//a.md") == "Inbox/a.md"
    assert notes.normalize_path("Journal/été.md") == "Journal/été.md"


def test_only_md_files_are_notes():
    assert notes.is_note_key("a/b.md") and not notes.is_note_key("photo.png") and not notes.is_note_key("a/b.md.png")


def test_obsidian_folder_is_invisible_to_list_and_search():
    assert not notes.is_note_key(".obsidian/plugins/x/notes.md")
    assert not any(".obsidian" in p for p in notes.list_notes(s3(), BUCKET))
    assert not any(".obsidian" in h["path"] for h in notes.search_notes(s3(), BUCKET, "Marie"))


def test_list_notes_honours_prefix_and_limit():
    assert notes.list_notes(s3(), BUCKET, prefix="Projects/") == ["Projects/deep/x.md", "Projects/plan.md"]
    assert len(notes.list_notes(s3(), BUCKET, limit=2)) == 2
    assert "photo.png" not in notes.list_notes(s3(), BUCKET)


def test_read_note_returns_text():
    assert "Marie Tremblay" in notes.read_note(s3(), BUCKET, "Inbox/a.md")


def test_read_note_over_one_mib_is_refused():
    before = STUB.gets
    raises(lambda: notes.read_note(s3(), BUCKET, "big.md"))
    assert notes.MAX_READ_BYTES == 1_048_576 and before <= STUB.gets  # refused on Content-Length, not after reading it all


def test_read_note_outside_the_rules_is_refused():
    for bad in (".obsidian/plugins/x/notes.md", "photo.png", "../x.md", "/Inbox/a.md", "missing.md"):
        raises(lambda: notes.read_note(s3(), BUCKET, bad))


def test_search_returns_bounded_snippets_and_stops_at_the_limit():
    hits = notes.search_notes(s3(), BUCKET, "marie")  # case-insensitive
    assert {h["path"] for h in hits} == {"Inbox/a.md", "Journal/2026-01-01.md"}
    assert all(len(h["snippet"]) <= notes.SNIPPET_CHARS + 2 for h in hits)
    assert len(notes.search_notes(s3(), BUCKET, "marie", limit=1)) == 1


def test_search_stops_after_max_scan_objects():
    old, notes.MAX_SCAN_OBJECTS = notes.MAX_SCAN_OBJECTS, 2
    before = STUB.gets
    try:
        notes.search_notes(s3(), BUCKET, "zzz-no-such-text")
    finally:
        notes.MAX_SCAN_OBJECTS = old
    assert STUB.gets - before <= 2, STUB.gets - before


def test_vault_prefix_is_applied_and_stripped():
    DATA["Vault/Inbox/z.md"] = b"zed"
    try:
        assert notes.list_notes(s3(), BUCKET, vault_prefix="Vault/") == ["Inbox/z.md"]
        assert notes.read_note(s3(), BUCKET, "Inbox/z.md", vault_prefix="Vault/") == "zed"
        raises(lambda: notes.read_note(s3(), BUCKET, "Inbox/a.md", vault_prefix="Vault/"))  # outside the vault
    finally:
        del DATA["Vault/Inbox/z.md"]


def test_notes_module_has_no_write_call():
    src = open(os.path.join(ROOT, "mcp", "obsidian", "notes.py")).read()
    for call in ("put_object", "delete_object", "copy_object", "upload_", "create_multipart", "delete_objects"):
        assert call not in src, call


def _client(token=TOKEN):
    from starlette.testclient import TestClient

    import server

    return TestClient(server.build_app(s3(), BUCKET, "", token))


RPC = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
HDR = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}


def test_server_rejects_a_missing_or_wrong_token():
    with _client() as c:
        assert c.post("/mcp", json=RPC, headers=HDR).status_code == 401
        assert c.post("/mcp", json=RPC, headers={**HDR, "Authorization": "Bearer nope"}).status_code == 401
        assert c.post("/mcp", json=RPC, headers={**HDR, "Authorization": TOKEN}).status_code == 401  # not a Bearer


def test_server_accepts_the_right_token_and_lists_the_three_tools():
    with _client() as c:
        r = c.post("/mcp", json=RPC, headers={**HDR, "Authorization": f"Bearer {TOKEN}"})
        assert r.status_code == 200, (r.status_code, r.text[:200])
        for tool in ("list_notes", "read_note", "search_notes"):
            assert tool in r.text, r.text[:300]


def test_health_needs_no_token_and_exposes_nothing():
    with _client() as c:
        r = c.get("/health")
        assert r.status_code == 200 and r.text == "ok"


def test_server_refuses_to_start_without_a_token():
    import server

    raises(lambda: server.build_app(s3(), BUCKET, "", ""))


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok    {name}")
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"  FAIL  {name}: {e!r}")
    sys.exit(1 if failed else 0)
