"""Organize the Obsidian vault's inbox, in its S3 copy.

Every run: pick the notes under Inbox/ that nobody has touched for
QUIET_MINUTES, ask Ollama for tags, a summary and one of the vault's existing
top-level folders, write that into the note's frontmatter and move the note
there.

The move is the only state: a note that has left Inbox/ is never looked at
again, so there is no table of processed notes to keep in sync -- and a
destination that already exists fails the note rather than being overwritten.

Why the quiet window: Remotely Save writes this bucket too, and a conflict
copy needs both sides to edit the same object between two syncs. A note
untouched for QUIET_MINUTES is outside that window -- a heuristic, not a lock;
raise ORGANIZER_QUIET_MINUTES if a conflict copy ever shows up. The bucket is
versioned, so every PUT and DELETE below can be undone from a prior version.

Obsidian resolves [[links]] by basename, not path, so moving a note does not
break links to it.
"""

from __future__ import annotations

import json
import os
import re
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any

import yaml
from prefect import flow, task

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://192.168.2.40:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.8:27b-mlx")
BUCKET = os.environ.get("ORGANIZER_S3_BUCKET", "obsidian")
# Remotely Save can be set to sync under a remote prefix; empty means the
# vault sits at the bucket root. Ends in "/" when set.
PREFIX = os.environ.get("ORGANIZER_VAULT_PREFIX", "")
INBOX = "Inbox/"
QUIET_MINUTES = int(os.environ.get("ORGANIZER_QUIET_MINUTES", "10"))
MAX_NOTES = int(os.environ.get("ORGANIZER_MAX_NOTES", "20"))
# ponytail: notes are cut to this many characters before the model sees them;
# raise it if long notes come back with shallow summaries.
MAX_CHARS = 12000

SYSTEM_PROMPT = (
    "You file notes in an Obsidian vault. Reply with JSON only: up to 5 short "
    "lowercase tags without '#', a one- or two-sentence summary written in the "
    "note's own language, and the single folder the note belongs in, chosen "
    "from this list: {folders}"
)

# Frontmatter is a leading `---` line, YAML, and a closing `---` line. The
# closing fence is matched as its own line (re.M) so an empty block
# (`---\n---\n`) is still recognized and never gets a second one stacked on.
_FRONTMATTER = re.compile(r"\A---[ \t]*\r?\n(.*?)^---[ \t]*(?:\r?\n|\Z)", re.S | re.M)


# --------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------


def split_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """(metadata, body). No frontmatter is ({}, text); a block that is not a
    YAML mapping raises ValueError rather than being silently replaced."""
    match = _FRONTMATTER.match(text)
    if not match:
        return {}, text
    meta = yaml.safe_load(match.group(1)) or {}
    if not isinstance(meta, dict):
        raise ValueError("frontmatter is not a YAML mapping")
    return meta, text[match.end():]


# The keys this flow writes. Everything else in the frontmatter is left as
# the text it was: a YAML load/dump round trip would rewrite values (1.1
# reads `12:30` as 750, `0123` as 83, `NO` as false) and drop comments.
OWN_KEYS = ("tags", "summary", "organized_at")


def _drop_keys(block: str, keys: tuple[str, ...]) -> str:
    """The frontmatter text minus the top-level entries for `keys`, with their
    continuation lines (indented lines, or `- item` lines at column 0)."""
    kept, skipping = [], False
    for line in block.splitlines(keepends=True):
        if line[:1] not in (" ", "\t", "-", "\r", "\n", ""):
            skipping = line.split(":", 1)[0].strip() in keys
        if not skipping:
            kept.append(line)
    out = "".join(kept)
    return out if not out or out.endswith("\n") else out + "\n"


def merge_frontmatter(text: str, tags: list[str], summary: str, now_iso: str) -> str:
    """Add tags (union, existing first), summary and organized_at. Every
    other line of the existing frontmatter is kept verbatim."""
    meta, body = split_frontmatter(text)
    match = _FRONTMATTER.match(text)
    kept = _drop_keys(match.group(1), OWN_KEYS) if match else ""
    existing = meta.get("tags") or []
    if isinstance(existing, str):
        existing = [existing]
    own = {
        "tags": list(dict.fromkeys([*existing, *tags])),
        "summary": summary,
        "organized_at": now_iso,
    }
    dumped = yaml.safe_dump(own, sort_keys=False, allow_unicode=True)
    return f"---\n{kept}{dumped}---\n{body}"


def top_level_folders(prefixes: list[str]) -> list[str]:
    """Folders a note may be filed into: every top-level one but the inbox
    and Obsidian's own dot-folders (.obsidian/, .trash/)."""
    return sorted(p for p in prefixes if p != INBOX and not p.startswith("."))


def destination_key(folder: str, key: str, prefix: str = PREFIX) -> str:
    return prefix + folder + key.rsplit("/", 1)[-1]


def pick_notes(objects: list[dict[str, Any]], now: datetime, quiet_minutes: int, limit: int) -> list[str]:
    """Markdown notes untouched for quiet_minutes, oldest first, at most limit."""
    cutoff = now - timedelta(minutes=quiet_minutes)
    quiet = [o for o in objects if o["Key"].endswith(".md") and o["LastModified"] <= cutoff]
    quiet.sort(key=lambda o: o["LastModified"])
    return [o["Key"] for o in quiet[:limit]]


def reply_schema(folders: list[str]) -> dict[str, Any]:
    """Ollama constrains decoding to this; the enum is built per run, so the
    model can only name a folder that exists."""
    return {
        "type": "object",
        "properties": {
            "tags": {"type": "array", "items": {"type": "string"}, "maxItems": 5},
            "summary": {"type": "string"},
            "folder": {"type": "string", "enum": folders},
        },
        "required": ["tags", "summary", "folder"],
    }


def parse_reply(content: str, folders: list[str]) -> dict[str, Any]:
    """Validate the model's reply anyway -- the schema is a decoding hint, and
    this is the last check before a file path is built from it."""
    data = json.loads(content)  # JSONDecodeError is a ValueError
    if not isinstance(data, dict):
        raise ValueError(f"reply is not an object: {content[:200]}")
    tags, summary, folder = data.get("tags"), data.get("summary"), data.get("folder")
    if folder not in folders:
        raise ValueError(f"model picked unknown folder {folder!r}")
    if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
        raise ValueError(f"tags is not a list of strings: {tags!r}")
    if not isinstance(summary, str) or not summary.strip():
        raise ValueError("empty summary")
    clean = [t.strip().lstrip("#").strip().lower().replace(" ", "-") for t in tags]
    return {"tags": [t for t in dict.fromkeys(clean) if t][:5], "summary": summary.strip(), "folder": folder}


# --------------------------------------------------------------------------
# I/O
# --------------------------------------------------------------------------


def classify(text: str, folders: list[str]) -> dict[str, Any]:
    body = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "format": reply_schema(folders),
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT.format(folders=", ".join(folders))},
            {"role": "user", "content": text[:MAX_CHARS]},
        ],
    }
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        reply = json.load(resp)
    return parse_reply(reply["message"]["content"], folders)


def _s3():
    # Imported here: boto3 is installed in the container by EXTRA_PIP_PACKAGES,
    # and keeping it out of import time lets the tests run without it.
    import boto3

    return boto3.client(
        "s3",
        endpoint_url=os.environ.get("ORGANIZER_S3_ENDPOINT", "http://s3:8333"),
        aws_access_key_id=os.environ.get("ORGANIZER_S3_ACCESS_KEY", "prefect"),
        aws_secret_access_key=os.environ["ORGANIZER_S3_SECRET_KEY"],
        region_name="us-east-1",
    )


def _exists(s3, key: str) -> bool:
    from botocore.exceptions import ClientError

    try:
        s3.head_object(Bucket=BUCKET, Key=key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise
    return True


# --------------------------------------------------------------------------
# Flow
# --------------------------------------------------------------------------


@task
def discover() -> tuple[list[str], list[str]]:
    """(folders, inbox notes to organize). ponytail: one page (1000 keys) per
    listing -- paginate if the vault ever outgrows that at its top level."""
    s3 = _s3()
    top = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX, Delimiter="/")
    folders = top_level_folders([p["Prefix"][len(PREFIX):] for p in top.get("CommonPrefixes", [])])
    inbox = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX + INBOX, Delimiter="/")
    notes = pick_notes(inbox.get("Contents", []), datetime.now(timezone.utc), QUIET_MINUTES, MAX_NOTES)
    return folders, notes


def retry_transient(task, task_run, state) -> bool:
    """Retry an unreachable Ollama or S3, not a note that cannot be filed:
    a bad reply (the model runs at temperature 0), bad frontmatter or a taken
    name fails the same way every time."""
    try:
        state.result()
    except (ValueError, FileExistsError):
        return False
    except Exception:  # noqa: BLE001 - anything else may be transient
        return True
    return True


@task(retries=2, retry_delay_seconds=30, retry_condition_fn=retry_transient)
def organize_note(key: str, folders: list[str]) -> str:
    s3 = _s3()
    text = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
    # The cheap checks first, so a note that can never be filed costs no
    # model call: unreadable frontmatter, and a name already in the vault
    # (in any folder -- two notes with one basename make [[links]] ambiguous).
    # ponytail: such notes still take a MAX_NOTES slot on every run; if the
    # inbox ever fills with them, nothing newer gets filed until they are fixed.
    split_frontmatter(text)
    for folder in folders:
        taken = destination_key(folder, key)
        if _exists(s3, taken):
            raise FileExistsError(f"{taken} already exists; {key} stays in the inbox -- rename one of them")
    reply = classify(text, folders)
    dest = destination_key(reply["folder"], key)
    now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
    body = merge_frontmatter(text, reply["tags"], reply["summary"], now_iso)
    s3.put_object(Bucket=BUCKET, Key=dest, Body=body.encode("utf-8"), ContentType="text/markdown; charset=utf-8")
    # Only after the PUT: if this DELETE fails, the note is in both places and
    # the next run fails loudly on "already exists" instead of losing it.
    s3.delete_object(Bucket=BUCKET, Key=key)
    print(f"{key} -> {dest} (tags: {', '.join(reply['tags'])})")
    return dest


@flow(name="organize-inbox", log_prints=True)
def organize_inbox() -> list[Any]:
    folders, notes = discover()
    if not notes:
        print(f"{PREFIX}{INBOX}: no note quiet for {QUIET_MINUTES} min")
        return []
    if not folders:
        raise RuntimeError("no top-level folder to file notes into")
    # One note at a time: one 27B model on one Mac, and parallel calls only
    # queue inside Ollama until they trip the request timeout. Returning the
    # states makes the run Failed if any note failed, while the rest still
    # get filed.
    return [organize_note(key, folders, return_state=True) for key in notes]
