"""Plain-assert checks for organize_inbox: the pure helpers, plus the write
path of organize_note against an in-memory S3 stand-in.

Run from the repo root:
  uv run --no-project --python 3.12 --with prefect==3.8.7 \
    python prefect/flows/test_organize_inbox.py
"""

from __future__ import annotations

import io
from datetime import datetime, timedelta, timezone

import organize_inbox as oi


def test_merge_keeps_keys_and_unions_tags():
    text = "---\ntitle: Hello\ntags: [a, b]\n---\nBody\n"
    out = oi.merge_frontmatter(text, ["b", "c"], "A summary.", "2026-09-27T12:00:00+00:00")
    meta, body = oi.split_frontmatter(out)
    assert meta["title"] == "Hello"
    assert meta["tags"] == ["a", "b", "c"]
    assert meta["summary"] == "A summary."
    assert meta["organized_at"] == "2026-09-27T12:00:00+00:00"
    assert body == "Body\n"


def test_merge_without_frontmatter():
    out = oi.merge_frontmatter("Just text\n", ["x"], "S", "T")
    meta, body = oi.split_frontmatter(out)
    assert meta == {"tags": ["x"], "summary": "S", "organized_at": "T"}
    assert body == "Just text\n"


def test_merge_empty_frontmatter():
    out = oi.merge_frontmatter("---\n---\nBody\n", ["x"], "S", "T")
    assert out.count("---\n") == 2, out
    meta, body = oi.split_frontmatter(out)
    assert meta["tags"] == ["x"]
    assert body == "Body\n"


def test_merge_string_or_null_tags():
    meta, _ = oi.split_frontmatter(oi.merge_frontmatter("---\ntags: solo\n---\nB\n", ["x"], "S", "T"))
    assert meta["tags"] == ["solo", "x"]
    meta, _ = oi.split_frontmatter(oi.merge_frontmatter("---\ntags:\n---\nB\n", ["x"], "S", "T"))
    assert meta["tags"] == ["x"]


def test_split_rejects_non_mapping_frontmatter():
    try:
        oi.split_frontmatter("---\n- a\n- b\n---\nbody\n")
    except ValueError:
        return
    raise AssertionError("a YAML list as frontmatter must be refused")


def test_top_level_folders():
    got = oi.top_level_folders(["Inbox/", ".obsidian/", ".trash/", "Projects/", "Areas/"])
    assert got == ["Areas/", "Projects/"]


def test_destination_key():
    assert oi.destination_key("Projects/", "Inbox/My note.md", prefix="") == "Projects/My note.md"
    assert oi.destination_key("Projects/", "vault/Inbox/n.md", prefix="vault/") == "vault/Projects/n.md"


def test_pick_notes():
    now = datetime(2026, 9, 27, 12, 0, tzinfo=timezone.utc)
    objects = [
        {"Key": "Inbox/old.md", "LastModified": now - timedelta(minutes=30)},
        {"Key": "Inbox/fresh.md", "LastModified": now - timedelta(minutes=2)},
        {"Key": "Inbox/image.png", "LastModified": now - timedelta(hours=1)},
        {"Key": "Inbox/older.md", "LastModified": now - timedelta(hours=2)},
    ]
    assert oi.pick_notes(objects, now, quiet_minutes=10, limit=20) == ["Inbox/older.md", "Inbox/old.md"]
    assert oi.pick_notes(objects, now, quiet_minutes=10, limit=1) == ["Inbox/older.md"]


def test_reply_schema_enum():
    schema = oi.reply_schema(["A/", "B/"])
    assert schema["properties"]["folder"]["enum"] == ["A/", "B/"]
    assert set(schema["required"]) == {"tags", "summary", "folder"}


def test_parse_reply_normalizes():
    got = oi.parse_reply('{"tags": ["#Deep Work", "ai", "ai"], "summary": " S ", "folder": "Projects/"}',
                         ["Areas/", "Projects/"])
    assert got == {"tags": ["deep-work", "ai"], "summary": "S", "folder": "Projects/"}


def test_parse_reply_rejects():
    folders = ["Areas/", "Projects/"]
    for bad in (
        "not json",
        '["a list"]',
        '{"tags": [], "summary": "S", "folder": "Nope/"}',
        '{"tags": "x", "summary": "S", "folder": "Areas/"}',
        '{"tags": [], "summary": "  ", "folder": "Areas/"}',
    ):
        try:
            oi.parse_reply(bad, folders)
        except ValueError:
            continue
        raise AssertionError(f"accepted: {bad}")


class FakeS3:
    def __init__(self, objects: dict[str, bytes]):
        self.objects = dict(objects)

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objects[Key] = Body

    def delete_object(self, Bucket, Key):
        del self.objects[Key]


def _wire(s3: FakeS3, reply: dict) -> None:
    oi._s3 = lambda: s3
    oi._exists = lambda client, key: key in client.objects
    oi.classify = lambda text, folders: reply


def test_organize_note_moves_and_enriches():
    s3 = FakeS3({"Inbox/n.md": b"Body\n"})
    _wire(s3, {"tags": ["x"], "summary": "S", "folder": "Projects/"})
    assert oi.organize_note.fn("Inbox/n.md", ["Projects/"]) == "Projects/n.md"
    assert "Inbox/n.md" not in s3.objects
    meta, body = oi.split_frontmatter(s3.objects["Projects/n.md"].decode("utf-8"))
    assert meta["tags"] == ["x"] and meta["summary"] == "S" and "organized_at" in meta
    assert body == "Body\n"


def test_organize_note_never_overwrites():
    s3 = FakeS3({"Inbox/n.md": b"new\n", "Projects/n.md": b"old\n"})
    _wire(s3, {"tags": ["x"], "summary": "S", "folder": "Projects/"})
    try:
        oi.organize_note.fn("Inbox/n.md", ["Projects/"])
    except FileExistsError:
        assert s3.objects == {"Inbox/n.md": b"new\n", "Projects/n.md": b"old\n"}
        return
    raise AssertionError("an existing destination must not be overwritten")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
