# Replace Airflow with Prefect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swap the stack's orchestrator from Airflow 3 to Prefect 3, port the nightly PR validation, and ship the first AI pipeline (an Ollama-driven organizer for the Obsidian vault's `Inbox/` in S3).

**Architecture:** Two Prefect containers on `infra-net`: `prefect-server` (API + UI, metadata in Postgres) and `prefect-flows`, which runs `serve()` over the flows bind-mounted from `prefect/flows/`. No work pool, no worker, no deploy step. The API is closed with Prefect's basic auth (it sits next to the Docker socket); the browser vhost is gated by a fourth oauth2-proxy against Keycloak realm `infra`, group `prefect`. Flows call Ollama's HTTP API directly with a JSON-schema `format`.

**Tech Stack:** Prefect 3.8.7 (`prefecthq/prefect:3.8.7-python3.12`), Python 3.12 stdlib + `pyyaml` (ships with Prefect) + `boto3` + `docker` (via `EXTRA_PIP_PACKAGES`), SeaweedFS S3, Ollama, oauth2-proxy v7.6.0, Keycloak, NGINX, Docker Compose under Portainer.

**Spec:** `docs/superpowers/specs/2026-09-27-prefect-orchestrator-design.md`

## Global Constraints

- Image: `prefecthq/prefect:3.8.7-python3.12` for both Prefect services. oauth2-proxy: `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`.
- No `ports:` on `prefect-server`, `prefect-flows`, `oauth2-proxy-prefect` (single-ingress rule).
- Every repo bind mount is `${INFRA_DIR:-.}/...` (Portainer runs compose from its own clone).
- Secrets that must exist before first boot get a `${VAR:?message}` guard; `PREFECT_OAUTH_CLIENT_SECRET` must **not** get one (Keycloak creates it).
- Cookie-secret recipes end in `| tr -- '+/' '-_'`.
- Container env for flow settings must **not** start with `PREFECT_` (Prefect reads that namespace as its own settings): use `ORGANIZER_*`, `OLLAMA_*`.
- The GitHub PAT never enters `.env`; it lives in the Prefect `Secret` block `infra-ci-github-token` and is loaded inside each task, never passed as a task parameter.
- The organizer never overwrites an object and deletes an inbox object only after a successful `PUT` of its destination.
- Schedules: `pr-validation/nightly` = `Cron("0 3 * * *", timezone="America/Toronto")`; `organize-inbox/every-15m` = `Interval(timedelta(minutes=15))`.
- Organizer defaults: `ORGANIZER_QUIET_MINUTES=10`, `ORGANIZER_MAX_NOTES=20`, inbox `Inbox/`, `ORGANIZER_VAULT_PREFIX` empty, bucket `obsidian`, S3 access key `prefect`, secret from `.env` `PREFECT_S3_SECRET_KEY`.
- Commit messages end with: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
- Work on branch `feat/prefect`; never deploy (`make up`) from a task — deployment is Task 6, done by the operator.

**Offline preflight** (referenced by Tasks 3–4; no Docker daemon needed). Run from the repo root:

```bash
git add -A
tmp="$(mktemp -d)"
git ls-files -z | tar --null -cf - -T - | tar -xf - -C "$tmp"
bash scripts/ci-fake-env.sh "$tmp" >/dev/null \
  && (cd "$tmp" && SKIP_DOCKER_CHECK=1 bash scripts/check-env.sh) \
  && (cd "$tmp" && docker compose --env-file .env -f docker-compose.yml config -q) \
  && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp/keycloak/realm-import/infra-realm.json" \
  && echo PREFLIGHT-OK
rm -rf "$tmp"
```

**Local Python runner** (Tasks 1–2):

```bash
uv run --no-project --python 3.12 --with prefect==3.8.7 python <script>
```

## Review Focus

1. **A note with empty (`---\n---`) or non-mapping frontmatter** — empty must not get a second frontmatter block stacked on top; a YAML list/scalar must fail that note without writing anything. Tests in Task 1 (`test_merge_empty_frontmatter`, `test_split_rejects_non_mapping_frontmatter`).
2. **The model picks a folder whose file name already exists** — must fail the note, leave both objects untouched, never overwrite. Test in Task 1 (`test_organize_note_never_overwrites`).
3. **The model replies with non-JSON, an unknown folder, a string for `tags`, or an empty summary** — must fail the note, nothing written. Test in Task 1 (`test_parse_reply_rejects`).
4. **Existing frontmatter where `tags` is a string or `null`** — must merge, not crash or drop the existing tag. Test in Task 1 (`test_merge_string_or_null_tags`).
5. **Inbox holds non-`.md` files, fresh edits, and more notes than `MAX_NOTES`** — only quiet `.md` notes, oldest first, capped. Test in Task 1 (`test_pick_notes`).

---

### Task 1: Organizer flow (`organize_inbox.py`) with its tests

**Files:**
- Create: `prefect/flows/organize_inbox.py`
- Test: `prefect/flows/test_organize_inbox.py`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Task 2's `serve.py`):
  - `organize_inbox` — `@flow(name="organize-inbox")`, no parameters, returns `list[State]`.
  - Pure helpers (used only by the tests): `split_frontmatter(text: str) -> tuple[dict, str]`, `merge_frontmatter(text: str, tags: list[str], summary: str, now_iso: str) -> str`, `top_level_folders(prefixes: list[str]) -> list[str]`, `destination_key(folder: str, key: str, prefix: str = PREFIX) -> str`, `pick_notes(objects: list[dict], now: datetime, quiet_minutes: int, limit: int) -> list[str]`, `reply_schema(folders: list[str]) -> dict`, `parse_reply(content: str, folders: list[str]) -> dict`.
  - Seams patched by the tests: module-level `_s3()`, `_exists(s3, key) -> bool`, `classify(text, folders) -> dict`; task `organize_note` (called via `organize_note.fn(key, folders)`).

- [ ] **Step 1: Write the failing test**

Create `prefect/flows/test_organize_inbox.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run --no-project --python 3.12 --with prefect==3.8.7 python prefect/flows/test_organize_inbox.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'organize_inbox'`

- [ ] **Step 3: Write the implementation**

Create `prefect/flows/organize_inbox.py`:

```python
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


def merge_frontmatter(text: str, tags: list[str], summary: str, now_iso: str) -> str:
    """Add tags (union, existing first), summary and organized_at. Every
    other existing key is kept as it was."""
    meta, body = split_frontmatter(text)
    existing = meta.get("tags") or []
    if isinstance(existing, str):
        existing = [existing]
    meta["tags"] = list(dict.fromkeys([*existing, *tags]))
    meta["summary"] = summary
    meta["organized_at"] = now_iso
    dumped = yaml.safe_dump(meta, sort_keys=False, allow_unicode=True)
    return f"---\n{dumped}---\n{body}"


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


@task(retries=2, retry_delay_seconds=30)
def organize_note(key: str, folders: list[str]) -> str:
    s3 = _s3()
    text = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
    reply = classify(text, folders)
    dest = destination_key(reply["folder"], key)
    if _exists(s3, dest):
        raise FileExistsError(f"{dest} already exists; {key} stays in the inbox -- rename one of them")
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run --no-project --python 3.12 --with prefect==3.8.7 python prefect/flows/test_organize_inbox.py`
Expected: one `ok test_...` line per test (13 lines), exit 0.

- [ ] **Step 5: Commit**

```bash
git add prefect/flows/organize_inbox.py prefect/flows/test_organize_inbox.py
git commit -m "feat(prefect): organize-inbox flow for the Obsidian vault's S3 copy

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Port PR validation and add `serve.py`

**Files:**
- Create: `prefect/flows/pr_validation.py`
- Create: `prefect/flows/serve.py`
- Reference (read, do not modify): `airflow/dags/infra_pr_validation.py` — deleted in Task 4.

**Interfaces:**
- Consumes: `organize_inbox` (flow) from Task 1.
- Produces: `pr_validation(repo: str = "nicolaslallier/Infra") -> list[State]` (`@flow(name="pr-validation")`); `serve.deployments() -> list[RunnerDeployment]`; `serve.py` as the `prefect-flows` container's command (Task 3).

This is a port: same checks, images, workspace path, comment marker and comment text. The only behaviour changes are the ones Prefect forces: the PAT comes from a `Secret` block instead of an Airflow Variable, the repo is a flow parameter instead of the `infra_ci_repo` Variable, and the footer names the Prefect flow. Known and deliberately **not** fixed here (spec: "logic changes are out of scope"): fork PRs clone `head_ref` from the base repo and fail at `clone`.

- [ ] **Step 1: Write the failing check**

Run:
```bash
uv run --no-project --python 3.12 --with prefect==3.8.7 python - <<'EOF'
import sys; sys.path.insert(0, "prefect/flows")
import pr_validation, serve
assert [c["name"] for c in pr_validation._checks("/w")] == ["shellcheck", "compose config", "nginx -t", "promtool"]
names = sorted(d.name for d in serve.deployments())
assert names == ["every-15m", "nightly"], names
print("ok")
EOF
```
Expected: FAIL with `ModuleNotFoundError: No module named 'pr_validation'`

- [ ] **Step 2: Write `prefect/flows/pr_validation.py`**

```python
"""Nightly validation of this repo's open pull requests.

Why this lives in Prefect and not in GitHub Actions: a GitHub-hosted runner
cannot reach `infra-net`, the Docker daemon this stack runs on, or anything on
the LAN. Prefect is already on that machine, so it is the only scheduler that
can eventually bring the stack up for real. This flow does not do that yet --
it runs the file-level checks -- but it establishes the plumbing the smoke
test will reuse: a workspace the nested containers can see, a clone step, and
a single upserted comment per PR.

How a run works, per open PR:

  1. clone the PR's head into $WORKSPACE_ROOT/pr-<n>-<run> (in a container,
     like every check)
  2. render a throwaway .env, seal key and certs into it
     (scripts/ci-fake-env.sh, from the PR's own checkout, so a PR that breaks
     that script fails here)
  3. run each check, most of them in the same image the real service uses
  4. post or update one comment on the PR

The load-bearing detail is WORKSPACE_ROOT. Checks run as sibling containers,
so their `-v <path>:/repo` is resolved by the *daemon*, against the host
filesystem -- not against this container's. A clone written to an ordinary
temp dir in here would be invisible to them, and Docker would silently
auto-create an empty directory in its place (the same trap `${INFRA_DIR}`
exists for, see "Portainer-managed stack" in CLAUDE.md). Mounting the
workspace at *the same path* inside and outside makes the two agree with no
translation. Consequence: this flow assumes prefect-flows and the daemon share
a filesystem. It does not work against a remote DOCKER_HOST.

Setup, once:
  - docker socket + workspace mount on prefect-flows (docker-compose.yml)
  - a Secret block `infra-ci-github-token` (a PAT with pull_requests:write),
    created in the Prefect UI
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.request
from typing import Any

from prefect import flow, task
from prefect.blocks.system import Secret
from prefect.runtime import flow_run

# Bind-mounted from the host at this same path (see the module docstring).
WORKSPACE_ROOT = "/tmp/infra-ci"

GITHUB_API = "https://api.github.com"

# Lets a later run find the comment it wrote last time instead of stacking a
# new one on every night's run. Invisible in the rendered comment.
COMMENT_MARKER = "<!-- infra-pr-validation -->"

# Images are pinned by tag rather than digest on purpose: these are throwaway
# validation containers, and a check that silently stops matching the image
# the stack actually deploys is worse than one that follows it.
IMG_GIT = "alpine/git:latest"
IMG_SHELLCHECK = "koalaman/shellcheck-alpine:stable"
IMG_DOCKER_CLI = "docker:28-cli"
IMG_NGINX = "nginx:alpine-otel"  # must match docker-compose.yml's nginx image
IMG_PROMETHEUS = "prom/prometheus:latest"


def _token() -> str:
    """The PAT, loaded inside each task that needs it rather than passed
    between tasks, so it is never recorded as a task parameter."""
    return Secret.load("infra-ci-github-token").get()


# --------------------------------------------------------------------------
# GitHub
# --------------------------------------------------------------------------


def _gh(path: str, token: str, method: str = "GET", body: dict | None = None) -> Any:
    """One GitHub REST call, stdlib only."""
    url = path if path.startswith("http") else f"{GITHUB_API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


# --------------------------------------------------------------------------
# Docker
# --------------------------------------------------------------------------


def _docker_run(
    image: str,
    command: list[str],
    volumes: dict[str, dict[str, str]],
    working_dir: str | None = None,
    user: str | None = None,
) -> tuple[int, str]:
    """Run one container to completion; return (exit code, combined output).

    create/start/wait/logs rather than containers.run() because run() raises on
    a non-zero exit and hands back only stderr -- and here a non-zero exit is
    the normal, interesting outcome that has to be reported with its full
    output, not an exception.
    """
    import docker  # installed by EXTRA_PIP_PACKAGES; imported late so importing this module never needs it

    client = docker.from_env()
    try:
        client.images.get(image)
    except docker.errors.ImageNotFound:
        client.images.pull(image)

    container = client.containers.create(
        image=image,
        command=command,
        volumes=volumes,
        working_dir=working_dir,
        user=user,
        network_mode="bridge",
    )
    try:
        container.start()
        status = container.wait(timeout=600)
        logs = container.logs(stdout=True, stderr=True).decode("utf-8", "replace")
        return int(status.get("StatusCode", 1)), logs
    finally:
        try:
            container.remove(force=True)
        except Exception:  # noqa: BLE001 - a leaked container must not fail the check
            pass


def _checks(workspace: str) -> list[dict[str, Any]]:
    """The container-run checks, as data.

    Each one mounts the workspace the way the real service mounts the repo, so
    a check exercises the same paths the deployed container would see -- that
    is the whole point of running `nginx -t` in `nginx:alpine-otel` rather than
    in some generic linter image.
    """
    ro = lambda path: {"bind": path, "mode": "ro"}  # noqa: E731

    return [
        {
            "name": "shellcheck",
            "image": IMG_SHELLCHECK,
            "command": [
                "sh",
                "-c",
                "shellcheck -S warning scripts/*.sh postgres/initdb/*.sh",
            ],
            "working_dir": "/repo",
            "volumes": {workspace: ro("/repo")},
        },
        {
            # Catches a ${VAR:?} with nothing behind it and a malformed
            # service block -- the two ways a deploy dies before any container
            # starts. Both compose projects, since portainer's is separate.
            "name": "compose config",
            "image": IMG_DOCKER_CLI,
            "command": [
                "sh",
                "-c",
                "docker compose --env-file .env -f docker-compose.yml config -q && "
                "docker compose --env-file .env -f docker-compose.portainer.yml config -q",
            ],
            "working_dir": "/repo",
            "volumes": {
                workspace: ro("/repo"),
                "/var/run/docker.sock": ro("/var/run/docker.sock"),
            },
        },
        {
            # The highest-value check in this repo: every `make up`
            # force-recreates nginx, so a typo in a new vhost takes down all
            # ingress at deploy time rather than at review time.
            "name": "nginx -t",
            "image": IMG_NGINX,
            "command": ["nginx", "-t"],
            "working_dir": None,
            "volumes": {
                f"{workspace}/nginx/nginx.conf": ro("/etc/nginx/nginx.conf"),
                f"{workspace}/nginx/conf.d": ro("/etc/nginx/conf.d"),
                f"{workspace}/nginx/stream.d": ro("/etc/nginx/stream.d"),
                f"{workspace}/nginx/snippets": ro("/etc/nginx/snippets"),
                f"{workspace}/certs": ro("/etc/nginx/certs"),
            },
        },
        {
            # Mounted at /etc/prometheus, not /repo: prometheus.yml names its
            # file_sd targets by their in-container absolute path, and promtool
            # checks that those files exist.
            "name": "promtool",
            "image": IMG_PROMETHEUS,
            "command": ["check", "config", "/etc/prometheus/prometheus.yml"],
            "working_dir": None,
            "entrypoint": "promtool",
            "volumes": {
                f"{workspace}/monitoring/prometheus/prometheus.yml": ro(
                    "/etc/prometheus/prometheus.yml"
                ),
                f"{workspace}/monitoring/prometheus/targets": ro("/etc/prometheus/targets"),
            },
        },
    ]


# --------------------------------------------------------------------------
# Checks that need no container
# --------------------------------------------------------------------------


def _check_json_yaml(workspace: str) -> tuple[int, str]:
    """Grafana dashboards and Keycloak realms are JSON that nothing parses
    until the container boots: a broken dashboard leaves Grafana up and simply
    missing it, with the error buried in its log."""
    import glob

    import yaml

    problems: list[str] = []
    checked = 0

    patterns_json = [
        "monitoring/grafana/provisioning/dashboards/json/*.json",
        "keycloak/realm-import/*.json",
    ]
    patterns_yaml = ["monitoring/**/*.yml", "*.yml"]

    for pattern in patterns_json:
        for path in sorted(glob.glob(os.path.join(workspace, pattern))):
            checked += 1
            try:
                with open(path, encoding="utf-8") as handle:
                    json.load(handle)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{os.path.relpath(path, workspace)}: {exc}")

    for pattern in patterns_yaml:
        for path in sorted(glob.glob(os.path.join(workspace, pattern), recursive=True)):
            checked += 1
            try:
                with open(path, encoding="utf-8") as handle:
                    list(yaml.safe_load_all(handle))
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{os.path.relpath(path, workspace)}: {exc}")

    if problems:
        return 1, "\n".join(problems)
    return 0, f"{checked} JSON/YAML files parse"


def _check_env_script(workspace: str) -> tuple[int, str]:
    """The repo's own preflight, run against the .env ci-fake-env.sh just
    rendered. It asserts that every key .env.example defines is present and
    correctly shaped, which is exactly what a PR adding a service forgets."""
    proc = subprocess.run(
        ["bash", "scripts/check-env.sh"],
        cwd=workspace,
        capture_output=True,
        text=True,
        timeout=120,
        env={**os.environ, "SKIP_DOCKER_CHECK": "1"},
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip() or "ok"


# --------------------------------------------------------------------------
# Flow
# --------------------------------------------------------------------------


@task
def list_open_prs(repo: str) -> list[dict[str, Any]]:
    prs = _gh(f"/repos/{repo}/pulls?state=open&per_page=50", _token())
    selected = [
        {
            "repo": repo,
            "number": pr["number"],
            "title": pr["title"],
            "head_sha": pr["head"]["sha"],
            "head_ref": pr["head"]["ref"],
            "clone_url": pr["head"]["repo"]["clone_url"] if pr["head"]["repo"] else None,
        }
        for pr in prs
        if not pr.get("draft")
    ]
    print(f"{len(selected)} open non-draft PR(s) on {repo}")
    return selected


@task(retries=1, retry_delay_seconds=120, timeout_seconds=1500)
def run_checks(pr: dict[str, Any]) -> dict[str, Any]:
    run_id = str(flow_run.id)
    workspace = os.path.join(WORKSPACE_ROOT, f"pr-{pr['number']}-{run_id}")

    token = _token()
    results: list[dict[str, Any]] = []

    try:
        os.makedirs(workspace, exist_ok=True)

        # The clone runs in a container like every check -- as this process's
        # uid, or the checkout lands owned by someone else and the steps below
        # cannot write .env into it.
        clone_url = f"https://x-access-token:{token}@github.com/{pr['repo']}.git"
        code, out = _docker_run(
            image=IMG_GIT,
            command=[
                "clone",
                "--depth",
                "1",
                "--branch",
                pr["head_ref"],
                clone_url,
                "/work",
            ],
            volumes={workspace: {"bind": "/work", "mode": "rw"}},
            user=f"{os.getuid()}:{os.getgid()}",
        )
        if code != 0:
            # Never let a token reach a task log or a PR comment.
            out = out.replace(token, "***")
            return {
                "pr": pr,
                "results": [{"name": "clone", "code": code, "output": out}],
            }

        # Throwaway .env / seal key / certs, from the PR's own copy of the
        # script -- so a PR that breaks it fails right here.
        prep = subprocess.run(
            ["bash", "scripts/ci-fake-env.sh", workspace],
            cwd=workspace,
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, "CI_FAKE_ENV_FORCE": "1"},
        )
        results.append(
            {
                "name": "prepare workspace",
                "code": prep.returncode,
                "output": (prep.stdout + prep.stderr).strip(),
            }
        )
        if prep.returncode != 0:
            return {"pr": pr, "results": results}

        for name, fn in (
            ("check-env", _check_env_script),
            ("json/yaml", _check_json_yaml),
        ):
            code, out = fn(workspace)
            results.append({"name": name, "code": code, "output": out})

        for check in _checks(workspace):
            kwargs = {
                "image": check["image"],
                "command": check["command"],
                "volumes": check["volumes"],
                "working_dir": check.get("working_dir"),
            }
            if check.get("entrypoint"):
                # promtool is a second binary in the prometheus image.
                kwargs["command"] = [check["entrypoint"], *check["command"]]
            code, out = _docker_run(**kwargs)
            results.append({"name": check["name"], "code": code, "output": out})

        return {"pr": pr, "results": results}
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


@task(retries=2, retry_delay_seconds=60)
def post_report(outcome: dict[str, Any]) -> None:
    token = _token()
    pr = outcome["pr"]
    results = outcome["results"]
    failed = [r for r in results if r["code"] != 0]

    header = (
        f"{COMMENT_MARKER}\n"
        f"### {'❌' if failed else '✅'} Validation infra — `{pr['head_sha'][:7]}`\n\n"
        f"| check | résultat |\n|---|---|\n"
    )
    rows = ""
    for r in results:
        verdict = "✅" if r["code"] == 0 else f"❌ (exit {r['code']})"
        rows += f"| `{r['name']}` | {verdict} |\n"
    details = ""
    for r in failed:
        body = r["output"][-3000:] or "(aucune sortie)"
        details += f"\n<details><summary><code>{r['name']}</code></summary>\n\n```\n{body}\n```\n\n</details>\n"

    footer = "\n<sub>Posté par le flow Prefect <code>pr-validation</code>.</sub>"
    comment = header + rows + details + footer

    existing = _gh(f"/repos/{pr['repo']}/issues/{pr['number']}/comments?per_page=100", token)
    mine = next((c for c in existing if COMMENT_MARKER in (c.get("body") or "")), None)

    if mine:
        _gh(
            f"/repos/{pr['repo']}/issues/comments/{mine['id']}",
            token,
            method="PATCH",
            body={"body": comment},
        )
    else:
        _gh(
            f"/repos/{pr['repo']}/issues/{pr['number']}/comments",
            token,
            method="POST",
            body={"body": comment},
        )

    if failed:
        raise RuntimeError(
            f"PR #{pr['number']}: {len(failed)} check(s) en échec — "
            + ", ".join(r["name"] for r in failed)
        )


@flow(name="pr-validation", log_prints=True)
def pr_validation(repo: str = "nicolaslallier/Infra") -> list[Any]:
    prs = list_open_prs(repo)
    outcomes = run_checks.map(prs)
    reports = post_report.map(outcomes)
    reports.wait()
    # Returning every state marks the run Failed if any PR's checks or report
    # did not complete, while each red PR is still its own failed task run.
    return [f.state for f in (*outcomes, *reports)]
```

- [ ] **Step 3: Write `prefect/flows/serve.py`**

```python
"""Entry point of the prefect-flows container.

serve() registers every deployment below (with its schedule) against the
Prefect API, then polls for runs and executes them as subprocesses of this
process. There is no work pool, no worker and no deploy step: a new or changed
flow takes effect when this container restarts, and every `make up`
force-recreates it anyway.

If the API is not up yet, serve() exits and `restart: unless-stopped` brings
it back -- the retry is the restart.
"""

from __future__ import annotations

from datetime import timedelta

from prefect import serve
from prefect.schedules import Cron, Interval

from organize_inbox import organize_inbox
from pr_validation import pr_validation


def deployments() -> list:
    return [
        pr_validation.to_deployment(
            name="nightly",
            schedule=Cron("0 3 * * *", timezone="America/Toronto"),
        ),
        organize_inbox.to_deployment(
            name="every-15m",
            schedule=Interval(timedelta(minutes=15)),
        ),
    ]


if __name__ == "__main__":
    serve(*deployments())
```

- [ ] **Step 4: Run the check to verify it passes**

Run the same command as Step 1.
Expected: `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add prefect/flows/pr_validation.py prefect/flows/serve.py
git commit -m "feat(prefect): port nightly PR validation; serve both deployments

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire in Prefect — services, gate, vhost, realm, env

**Files:**
- Modify: `docker-compose.yml` (add three services)
- Create: `nginx/conf.d/prefect.conf`
- Modify: `keycloak/realm-import/infra-realm.json` (group + client)
- Modify: `keycloak/CLAUDE.md` (document the client)
- Modify: `.env.example` (new keys; `prefect` in `APP_DATABASES`)
- Modify: `scripts/check-env.sh` (REQUIRED, COOKIE_SECRETS, POST_BOOT, auth-string shape)
- Modify: `scripts/ci-fake-env.sh` (render the new keys)
- Modify: `scripts/print-hosts-entries.sh` (`airflow` host → `prefect` host)

**Interfaces:**
- Consumes: `prefect/flows/serve.py` (Task 2) as `prefect-flows`'s command; env names read by Task 1's module: `OLLAMA_URL`, `OLLAMA_MODEL`, `ORGANIZER_S3_ENDPOINT`, `ORGANIZER_S3_BUCKET`, `ORGANIZER_S3_ACCESS_KEY`, `ORGANIZER_S3_SECRET_KEY`, `ORGANIZER_VAULT_PREFIX`.
- Produces: `.env` keys `PREFECT_DB_PASSWORD`, `PREFECT_AUTH_STRING`, `PREFECT_S3_SECRET_KEY`, `PREFECT_OAUTH_CLIENT_SECRET`, `PREFECT_OAUTH_COOKIE_SECRET`, `ORGANIZER_VAULT_PREFIX`; Keycloak group/client `prefect` in realm `infra`; host `prefect.infra.famillelallier.net`.

Airflow stays in place during this task — Task 4 removes it — so the preflight here proves the additions alone.

- [ ] **Step 1: Run the preflight against a check that will fail**

Add the shape check first so it has something to fail on. In `scripts/check-env.sh`, insert immediately before the line `if [ -z "${LAN_IP:-}" ]; then`:

```bash
# Prefect's basic auth splits the string on its first ':'. Without one, every
# API call -- the UI's and prefect-flows' alike -- is refused with a bare 401.
if [ -n "${PREFECT_AUTH_STRING:-}" ] && [ "$PREFECT_AUTH_STRING" != "$PLACEHOLDER" ] \
	&& ! [[ "$PREFECT_AUTH_STRING" =~ ^[^:]+:.+$ ]]; then
	errors+=("PREFECT_AUTH_STRING must be user:password (e.g. \"admin:\$(openssl rand -hex 16)\")")
fi

```

Then append to `.env.example`, immediately after the line `AIRFLOW_JWT_SECRET=change-me`:

```bash

# --- Prefect (https://prefect.infra.famillelallier.net) ---
# Basic auth for the Prefect API *and* UI, as user:password. Mandatory:
# prefect-flows holds the Docker socket, so an open API would be root on the
# daemon for every container on infra-net. check-env asserts the colon.
#   echo "admin:$(openssl rand -hex 16)"
PREFECT_AUTH_STRING=change-me
# oauth2-proxy-prefect (realm `infra`, client `prefect`, group `prefect`)
# gates the browser vhost in front of that password. The client secret is
# generated by Keycloak (copy it from the client's Credentials tab, or see
# the cutover in docs/superpowers/plans/2026-09-27-prefect-orchestrator.md);
# the cookie key is yours:
#   openssl rand -base64 32 | tr -- '+/' '-_'
PREFECT_OAUTH_CLIENT_SECRET=change-me
PREFECT_OAUTH_COOKIE_SECRET=change-me
# organize-inbox's S3 identity `prefect`, scoped to the `obsidian` bucket:
# `make s3-provision app=prefect bucket=obsidian` reads this.
#   openssl rand -hex 24
PREFECT_S3_SECRET_KEY=change-me
# Remote prefix Remotely Save syncs the vault under, ending in "/"; empty
# when the vault sits at the bucket root.
ORGANIZER_VAULT_PREFIX=
```

and in the `# --- Per-app databases ---` block change `APP_DATABASES=jarvis,nurse,keycloak,grafana,ea,airflow` to `APP_DATABASES=jarvis,nurse,keycloak,grafana,ea,airflow,prefect`, then add after the line `AIRFLOW_DB_PASSWORD=change-me`:

```bash
# Embedded in Prefect's asyncpg URL: letters/digits only.
PREFECT_DB_PASSWORD=change-me
```

Run the **offline preflight** (Global Constraints).
Expected: FAIL — `check-env` reports `PREFECT_AUTH_STRING must be user:password` (ci-fake-env's blanket pass turned `change-me` into a colon-less hex string). This proves the new check runs.

- [ ] **Step 2: Render the new keys in `scripts/ci-fake-env.sh`**

In the header comment, replace the line
`#   - the three oauth2-proxy cookie keys decode as 32 bytes under Go's`
with
`#   - the four oauth2-proxy cookie keys decode as 32 bytes under Go's`
and after the line `#   - AIRFLOW_DB_PASSWORD sits inside a URL, so it stays url-safe` add:

```bash
#   - PREFECT_DB_PASSWORD sits inside a URL, so it stays url-safe
#   - PREFECT_AUTH_STRING is user:password (check-env asserts the colon)
```

After `cookie_c="$(b64_32 | tr -d '=')"` add:

```bash
cookie_d="$(b64_32 | tr -d '=')"
```

After `set_key S3_ADMIN_OAUTH_COOKIE_SECRET "$cookie_c"` add:

```bash
set_key PREFECT_OAUTH_COOKIE_SECRET "$cookie_d"
set_key PREFECT_AUTH_STRING "admin:$(rand_hex 16)"
set_key PREFECT_DB_PASSWORD "$(rand_hex 16)"
```

- [ ] **Step 3: Register the secrets in `scripts/check-env.sh`**

In `REQUIRED=(`, after `S3_ADMIN_OAUTH_COOKIE_SECRET` add:

```bash
	PREFECT_AUTH_STRING
	PREFECT_S3_SECRET_KEY
	PREFECT_OAUTH_COOKIE_SECRET
```

(`PREFECT_DB_PASSWORD` is added automatically from `APP_DATABASES`.)

In `COOKIE_SECRETS=(`, after `S3_ADMIN_OAUTH_COOKIE_SECRET` add `	PREFECT_OAUTH_COOKIE_SECRET`.

In `POST_BOOT=(`, after `S3_ADMIN_OAUTH_CLIENT_SECRET:oauth2-proxy-infra:infra:s3-admin` add `	PREFECT_OAUTH_CLIENT_SECRET:oauth2-proxy-prefect:infra:prefect`.

- [ ] **Step 4: Add the compose services**

In `docker-compose.yml`, insert immediately before the line `  nginx:` (the one followed by `    # -otel variant: same image plus ngx_otel_module`):

```yaml
  # Fourth oauth2-proxy, for the Prefect UI (nginx/conf.d/prefect.conf),
  # against the `infra` realm like oauth2-proxy-infra -- its own container
  # because that one's REDIRECT_URL and host-scoped cookie are bound to the
  # s3-admin hostname. It gates people; PREFECT_AUTH_STRING gates the API,
  # which prefect-flows reaches directly on infra-net, never through here.
  oauth2-proxy-prefect:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      # Internal infra-net URL + the issuer-verification escape hatch, for
      # the same Keycloak hostname-v2 reason documented on oauth2-proxy above.
      OAUTH2_PROXY_OIDC_ISSUER_URL: http://keycloak:8080/realms/infra
      OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION: "true"
      OAUTH2_PROXY_CLIENT_ID: prefect
      # Client secret: generated by Keycloak, so no :? guard.
      # Cookie key: needed before the first boot, so it has one.
      OAUTH2_PROXY_CLIENT_SECRET: ${PREFECT_OAUTH_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${PREFECT_OAUTH_COOKIE_SECRET:?Set PREFECT_OAUTH_COOKIE_SECRET in .env (openssl rand -base64 32 | tr -- '+/' '-_' -- base64url, not standard base64)}
      OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256
      OAUTH2_PROXY_COOKIE_NAME: _oauth2_proxy_prefect
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_REDIRECT_URL: https://prefect.infra.famillelallier.net/oauth2/callback
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_ALLOWED_GROUPS: prefect
      # Same pin as oauth2-proxy-infra: ALLOWED_GROUPS would otherwise add a
      # `groups` scope Keycloak does not have (invalid_scope); the claim comes
      # from the client's group-membership mapper regardless.
      OAUTH2_PROXY_SCOPE: "openid email profile"
      OAUTH2_PROXY_UPSTREAMS: static://202
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
    volumes:
      # Same local-CA bundle swap as the other instances.
      - ${INFRA_DIR:-.}/certs/oauth2proxy-ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro
    networks:
      - infra-net
    depends_on:
      keycloak:
        condition: service_healthy

```

Then insert immediately before the line `  # --- Airflow (UI + REST API via NGINX; no host ports) ---`:

```yaml
  # --- Prefect (UI + API via NGINX behind oauth2-proxy-prefect; no host ports) ---

  prefect-server:
    image: prefecthq/prefect:3.8.7-python3.12
    restart: unless-stopped
    command: ["prefect", "server", "start", "--host", "0.0.0.0"]
    environment:
      # Database/role `prefect`, provisioned like any other app
      # (APP_DATABASES). The password sits inside a URL: keep it url-safe.
      PREFECT_API_DATABASE_CONNECTION_URL: postgresql+asyncpg://prefect:${PREFECT_DB_PASSWORD}@postgres:5432/prefect
      # Not optional. prefect-flows holds the Docker socket and a
      # deployment's pull steps can run shell commands, so an open API would
      # be root on the daemon for every container on infra-net -- a path
      # nginx and oauth2-proxy are not on. The UI prompts for the same string.
      PREFECT_SERVER_API_AUTH_STRING: ${PREFECT_AUTH_STRING:?Set PREFECT_AUTH_STRING in .env (user:password)}
      # Where the browser finds the API; the default would be 0.0.0.0:4200.
      PREFECT_UI_API_URL: https://prefect.infra.famillelallier.net/api
    networks:
      - infra-net
    depends_on:
      postgres:
        condition: service_healthy

  prefect-flows:
    image: prefecthq/prefect:3.8.7-python3.12
    restart: unless-stopped
    # serve.py registers every deployment with its schedule and runs flows as
    # subprocesses of this container: no work pool, no worker, no deploy
    # step. If the API is not up yet it exits, and the restart is the retry
    # (no healthcheck on prefect-server: with auth on, one would need the
    # secret on its command line).
    working_dir: /opt/prefect/flows
    command: ["python", "serve.py"]
    environment:
      # Installed by the image's entrypoint on every start; no custom image.
      EXTRA_PIP_PACKAGES: "docker boto3"
      PREFECT_API_URL: http://prefect-server:4200/api
      PREFECT_API_AUTH_STRING: ${PREFECT_AUTH_STRING:?Set PREFECT_AUTH_STRING in .env (user:password)}
      # organize-inbox. Not PREFECT_*: Prefect reads that namespace as its
      # own settings.
      OLLAMA_URL: ${OLLAMA_URL:-http://192.168.2.40:11434}
      OLLAMA_MODEL: ${OLLAMA_MODEL:-qwen3.8:27b-mlx}
      ORGANIZER_S3_ENDPOINT: http://s3:8333
      ORGANIZER_S3_BUCKET: obsidian
      # provision-s3.sh makes the access key the app name.
      ORGANIZER_S3_ACCESS_KEY: prefect
      ORGANIZER_S3_SECRET_KEY: ${PREFECT_S3_SECRET_KEY:?Set PREFECT_S3_SECRET_KEY in .env (openssl rand -hex 24), then make s3-provision app=prefect bucket=obsidian}
      ORGANIZER_VAULT_PREFIX: ${ORGANIZER_VAULT_PREFIX:-}
    # This is the one Prefect container that gets the Docker socket, for
    # pr-validation's sibling-container checks. Understand the trade before
    # extending it: the socket is root on the daemon, so any flow can do
    # anything to any container on this host. What stands between that and
    # the rest of infra-net is PREFECT_AUTH_STRING on prefect-server.
    volumes:
      - ${INFRA_DIR:-.}/prefect/flows:/opt/prefect/flows:ro
      - /var/run/docker.sock:/var/run/docker.sock
      # Checks run as *sibling* containers, so their bind mounts are resolved
      # by the daemon against the host -- a workspace at an ordinary temp path
      # in here would be invisible to them and Docker would auto-create an
      # empty directory in its place. Mounting it at the same path on both
      # sides is what makes the nested `-v` agree. Keep the two identical.
      - /tmp/infra-ci:/tmp/infra-ci
    # The socket is root-owned inside Docker Desktop's VM. If a check reports
    # permission denied on /var/run/docker.sock, `ls -l` it from inside this
    # container and add that gid here.
    group_add:
      - "0"
    networks:
      - infra-net
    depends_on:
      - prefect-server

```

- [ ] **Step 5: Add the vhost**

Create `nginx/conf.d/prefect.conf`:

```nginx
# Prefect UI + API. Two gates, neither a substitute for the other: this
# vhost's auth_request against oauth2-proxy-prefect (realm `infra`, group
# `prefect`) keeps people out, and PREFECT_SERVER_API_AUTH_STRING keeps
# everything else on infra-net out of the API -- prefect-flows reaches
# prefect-server:4200 directly and never passes through here. After SSO the
# UI prompts for that string and sends it as Authorization: Basic, which
# rides through to the upstream untouched. Same auth_request recipe as
# s3-admin.conf; the cookie is host-scoped and `rd` never leaves this host.
server {
    listen 443 ssl;
    server_name prefect.infra.famillelallier.net;

    include /etc/nginx/snippets/ssl.conf;

    resolver 127.0.0.11 valid=10s;

    location = /oauth2/auth {
        internal;
        set $oauth2_upstream http://oauth2-proxy-prefect:4180;
        proxy_pass $oauth2_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;
    }

    location /oauth2/ {
        set $oauth2_upstream http://oauth2-proxy-prefect:4180;
        proxy_pass $oauth2_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;
    }

    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in?rd=$request_uri;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;

        # proxy.conf carries the Upgrade headers the UI's event websocket needs.
        set $upstream http://prefect-server:4200;
        proxy_pass $upstream;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

In `scripts/print-hosts-entries.sh`, replace `AIRFLOW_HOST="airflow.infra.famillelallier.net"` with `PREFECT_HOST="prefect.infra.famillelallier.net"`, and both lines `$IP $AIRFLOW_HOST` with `$IP $PREFECT_HOST`.

- [ ] **Step 6: Add the Keycloak group and client**

In `keycloak/realm-import/infra-realm.json`, change the `groups` array to:

```json
  "groups": [
    { "name": "s3-admin" },
    { "name": "s3-readwrite" },
    { "name": "s3-readonly" },
    { "name": "prefect" }
  ],
```

and add this object as the last element of `clients` (after the `s3-sts` client, with a comma after `s3-sts`'s closing brace):

```json
    {
      "clientId": "prefect",
      "name": "Prefect UI (oauth2-proxy-prefect gate)",
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "implicitFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://prefect.infra.famillelallier.net"
      },
      "redirectUris": ["https://prefect.infra.famillelallier.net/oauth2/callback"],
      "webOrigins": [],
      "protocolMappers": [
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": { "claim.name": "groups", "full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true" }
        },
        {
          "name": "prefect-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": { "included.client.audience": "prefect", "id.token.claim": "true", "access.token.claim": "true" }
        }
      ]
    }
```

In `keycloak/CLAUDE.md`, section "Infra: SeaweedFS admin gate and STS (realm `infra`)": change the heading to `## Infra: SeaweedFS admin gate, STS and Prefect (realm \`infra\`)`, change `- Groups \`s3-admin\`, \`s3-readwrite\`, \`s3-readonly\`, emitted as the \`groups\`` to `- Groups \`s3-admin\`, \`s3-readwrite\`, \`s3-readonly\`, \`prefect\`, emitted as the \`groups\``, and insert after the `s3-sts` bullet (before the `` `--import-realm` only seeds`` paragraph):

```markdown
- `prefect`: confidential, PKCE S256, one exact redirect URI
  `https://prefect.infra.famillelallier.net/oauth2/callback`, for
  `oauth2-proxy-prefect` (`OAUTH2_PROXY_ALLOWED_GROUPS: prefect`). Its secret
  goes into `PREFECT_OAUTH_CLIENT_SECRET`. The realm already exists on the
  live cluster, so this client and the `prefect` group were created there
  with `kcadm`, not by import.
```

- [ ] **Step 7: Run the preflight to verify it passes**

Run the **offline preflight** (Global Constraints).
Expected: `PREFLIGHT-OK`. `check-env` may print warnings; it must not print errors.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml nginx/conf.d/prefect.conf keycloak/realm-import/infra-realm.json keycloak/CLAUDE.md .env.example scripts/check-env.sh scripts/ci-fake-env.sh scripts/print-hosts-entries.sh
git commit -m "feat(prefect): prefect-server, prefect-flows and the oauth2-proxy-prefect gate

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Remove Airflow

**Files:**
- Modify: `docker-compose.yml` (anchor, four services, volume)
- Delete: `airflow/` (the DAG), `nginx/conf.d/airflow.conf`
- Modify: `.env.example`, `scripts/check-env.sh`, `scripts/ci-fake-env.sh`, `scripts/ci-deploy.sh` (comments only)

**Interfaces:**
- Consumes: Task 3's Prefect services (they replace what is removed).
- Produces: a tree where `git grep -i airflow` outside Markdown finds nothing.

- [ ] **Step 1: Write the failing check**

Run: `git grep -n -i airflow -- . ':!*.md' ':!docs/**'`
Expected: FAIL — matches in `docker-compose.yml`, `.env.example`, `scripts/*.sh`, `airflow/`, `nginx/conf.d/airflow.conf`.

- [ ] **Step 2: Remove from `docker-compose.yml`**

Delete, in full:
- the comment `# Shared by every airflow-* service. LocalExecutor: tasks run as` / `# subprocesses of airflow-scheduler, so there is no Celery broker or worker.` and the whole `x-airflow-common: &airflow-common` block below it, up to (not including) the blank line before `services:`;
- from `  # --- Airflow (UI + REST API via NGINX; no host ports) ---` through the end of the `airflow-dag-processor` service (the line `        condition: service_completed_successfully` just before `networks:` at column 0);
- the line `  airflow-logs:` under the top-level `volumes:`.

- [ ] **Step 3: Delete files and remove keys**

```bash
git rm -r airflow nginx/conf.d/airflow.conf
```

In `.env.example`:
- `APP_DATABASES=jarvis,nurse,keycloak,grafana,ea,airflow,prefect` → `APP_DATABASES=jarvis,nurse,keycloak,grafana,ea,prefect`;
- delete `# Embedded in Airflow's SQLAlchemy URL: letters/digits only.` and `AIRFLOW_DB_PASSWORD=change-me`;
- delete the whole `# --- Airflow (https://airflow.infra.famillelallier.net) ---` block through `AIRFLOW_JWT_SECRET=change-me` (keep one blank line before `# --- Prefect`).

In `scripts/check-env.sh`, delete the four `REQUIRED` lines `AIRFLOW_DB_PASSWORD`, `AIRFLOW_ADMIN_PASSWORD`, `AIRFLOW_FERNET_KEY`, `AIRFLOW_JWT_SECRET`.

In `scripts/ci-fake-env.sh`:
- header: `# caller is CI on a disposable workspace (see airflow/dags/infra_pr_validation.py).` → `# caller is CI on a disposable workspace (see prefect/flows/pr_validation.py).`;
- delete the header lines `#   - AIRFLOW_FERNET_KEY is url-safe base64 of 32 bytes, padding kept` and `#   - AIRFLOW_DB_PASSWORD sits inside a URL, so it stays url-safe`;
- `# 32 random bytes, url-safe base64. Padding stripped for the cookie keys` / `# (oauth2-proxy decodes with RawURLEncoding), kept for the Fernet key.` → `# 32 random bytes, url-safe base64; padding stripped below for the cookie` / `# keys (oauth2-proxy decodes with RawURLEncoding).`;
- delete `fernet="$(b64_32)"` and the three lines `set_key AIRFLOW_FERNET_KEY "$fernet"`, `set_key AIRFLOW_JWT_SECRET "$(rand_hex 32)"`, `set_key AIRFLOW_DB_PASSWORD "$(rand_hex 16)"`.

In `scripts/ci-deploy.sh` (comments only):
- `# airflow/dags/infra_pr_validation.py uses for its workspace, and for the` → `# prefect/flows/pr_validation.py uses for its workspace, and for the`;
- `    # error -- the trap ${INFRA_DIR} and the airflow workspace mount are both` → `    # error -- the trap ${INFRA_DIR} and the prefect-flows workspace mount are both`.

- [ ] **Step 4: Run the checks to verify they pass**

Run: `git grep -n -i airflow -- . ':!*.md' ':!docs/**'`
Expected: no output (exit 1).

Run the **offline preflight** (Global Constraints).
Expected: `PREFLIGHT-OK`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(prefect): remove Airflow

Prefect's pr-validation flow replaces infra_pr_validation. The airflow
database and role are left in place; dropping them is a manual step after
the first green nightly run.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md`, `README.md`

**Interfaces:**
- Consumes: names from Tasks 1–4 (services, env keys, flows, Secret block, hostname).
- Produces: docs with no Airflow left outside `docs/superpowers/`.

- [ ] **Step 1: Write the failing check**

Run: `git grep -n -i airflow -- CLAUDE.md AGENTS.md README.md`
Expected: FAIL — matches in all three.

- [ ] **Step 2: `CLAUDE.md`**

(a) Replace the whole `- **\`airflow-*\`** — ...` bullet under "Architecture" (from that line through `  for what they are for and what the socket costs.`) with:

```markdown
- **`prefect-*`** — `prefecthq/prefect:3.8.7-python3.12`, at
  `prefect.infra.famillelallier.net` (NGINX → `prefect-server:4200`, gated
  by a **fourth** oauth2-proxy, `oauth2-proxy-prefect`: realm `infra`, client
  and group `prefect`). Publishes no host port. Two containers:
  `prefect-server` (API + UI; metadata in the provisioned Postgres
  database/role `prefect` — on an existing cluster run
  `make provision-app app=prefect` before the first deploy) and
  `prefect-flows`, which runs `prefect/flows/serve.py`: `serve()` registers
  every deployment with its schedule and executes runs as subprocesses, so
  there is no work pool, no worker and no deploy step. Flows are
  bind-mounted read-only from `prefect/flows/` and must be committed (the
  drift guard refuses untracked files); a changed flow takes effect on the
  next `make up`, which recreates `prefect-flows` anyway. `prefect-flows`
  alone carries the Docker socket and the `/tmp/infra-ci` workspace — see
  "Prefect: pipelines" below for what they are for, and why
  `PREFECT_AUTH_STRING` is not optional.
```

(b) In "CI: deploying on a push to main": `ingress to either — the same reason \`airflow/dags/\` exists rather than a` → `ingress to either — the same reason \`prefect/flows/pr_validation.py\` exists rather than a`.

(c) In "Single-ingress rule": in the list of reverse-proxy targets, after `` `s3-admin:23646` (behind `oauth2-proxy-infra`), `` add `` `prefect-server:4200` (behind `oauth2-proxy-prefect`), ``; and in the **Do not add a `ports:` entry** list, `` `oauth2-proxy-infra`, `` → `` `oauth2-proxy-infra`, `oauth2-proxy-prefect`, `` and `` `airflow-*` `` → `` `prefect-*` ``.

(d) Replace the whole section from `### Airflow: nightly PR validation` up to (not including) `### Windows machines (\`windows_exporter\`)` with:

````markdown
### Prefect: pipelines

`prefect-flows` serves two deployments from `prefect/flows/`:
`pr-validation/nightly` (03:00 America/Toronto) and
`organize-inbox/every-15m`. They are live as soon as `serve()` registers
them — nothing arrives paused.

**Two gates, and neither replaces the other.** `prefect-flows` holds the
Docker socket, and a deployment's `pull` steps can run shell commands — so
whoever can write to Prefect's API is root on the daemon. Prefect OSS's API
is open by default, and it is reachable at `prefect-server:4200` from every
container on `infra-net` (LibreChat, Jarvis, EA, …), a path NGINX is not on.
`PREFECT_AUTH_STRING` (`PREFECT_SERVER_API_AUTH_STRING` on the server,
`PREFECT_API_AUTH_STRING` on `prefect-flows`) closes it and has a `:?`
guard; `check-env` also asserts its `user:password` shape, since without a
colon every call gets a bare 401. `oauth2-proxy-prefect` gates the browser
vhost on top: SSO first, then Prefect's own password prompt.

**Models are called directly — the convention for every pipeline.** Flows
`POST` Ollama's `/api/chat` (`OLLAMA_URL`, default
`http://192.168.2.40:11434`, the instance LibreChat uses) with a JSON-schema
`format`, and validate the reply before acting on it. Not LibreChat's Agents
API, not an MCP agent loop: the flow owns the control flow, the model owns
only judgement.

Flow settings in `prefect-flows`' environment are `ORGANIZER_*` / `OLLAMA_*`,
never `PREFECT_*` — Prefect reads that namespace as its own settings.

#### `pr-validation`

At 03:00 it lists the open, non-draft PRs on GitHub, and for each one clones
the head, renders a throwaway `.env` into it, runs the file-level checks, and
posts (or updates) a single comment on the PR. A failing check fails that
PR's mapped task, so the UI shows which PR is red without opening GitHub.

Why here and not in GitHub Actions: a GitHub-hosted runner cannot reach
`infra-net`, this daemon, or anything on the LAN. The checks do not need any
of that — but the smoke test this flow is scaffolding for can only ever run
on this machine, and that is what the workspace and socket plumbing is for.

Four things here are load-bearing.

- **`WORKSPACE_ROOT` is mounted at the same path inside and outside the
  container** (`/tmp/infra-ci:/tmp/infra-ci` on `prefect-flows`). The checks
  run as *sibling* containers, so their `-v <path>:/repo` is resolved by the
  **daemon**, against the host filesystem. A clone written anywhere else would
  be invisible to them, and Docker would auto-create an empty directory in its
  place: the same trap `${INFRA_DIR:-.}` exists for. The cost is that this
  flow does not work against a remote `DOCKER_HOST`.
- **Only `prefect-flows` gets the Docker socket.** `prefect-server` has no
  reason to hold it. If the flow goes away, remove the mount with it.
- **Each check runs in the image the real service uses**, mounted the way the
  real service mounts the repo — `nginx -t` inside `nginx:alpine-otel`,
  `promtool check config` with `monitoring/prometheus/` at `/etc/prometheus`.
- **`scripts/ci-fake-env.sh` comes from the PR's own checkout**, so a PR that
  breaks it fails on its own change. It renders values shaped the way
  `check-env.sh` demands, which is why running the preflight against it is a
  meaningful check. It refuses to overwrite an existing `.env` unless
  `CI_FAKE_ENV_FORCE=1`.

Setup, once: in the Prefect UI, **Blocks → Secret**, name
`infra-ci-github-token`, value a PAT with `pull_requests:write`. The repo is
the flow parameter `repo` (default `nicolaslallier/Infra`). The PAT is a
Secret block, not a `.env` key, for the reason `PORTAINER_API_KEY` lives in
`.portainer.env`: `.env` is handed to containers wholesale and shipped to
Portainer, and this token can write to GitHub. The obvious next move is
`infra/apps/prefect` in OpenBao — it would be the vault's first real
consumer. A nightly schedule on a Mac that sleeps does not fire — either
`sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00`, or move the schedule.

#### `organize-inbox`

Every 15 minutes it takes the notes under `Inbox/` in the `obsidian` bucket
that nobody has touched for `ORGANIZER_QUIET_MINUTES` (10), at most
`ORGANIZER_MAX_NOTES` (20), oldest first; asks Ollama for tags, a summary and
one of the vault's existing top-level folders (a JSON-schema `enum` built per
run, so it cannot invent one); merges `tags`/`summary`/`organized_at` into
the frontmatter; and moves the note there. It talks to S3 only — never to the
Obsidian app — as identity `prefect` (`make s3-provision app=prefect
bucket=obsidian`, secret `PREFECT_S3_SECRET_KEY`), separate from Remotely
Save's `obsidian` identity.

- **The move is the only state.** A note that has left `Inbox/` is never
  seen again; there is no table of processed notes.
- **It never overwrites.** A destination that exists fails the note and
  leaves both objects alone. The inbox object is deleted only after the
  destination `PUT` succeeded; if that `DELETE` fails, the next run fails
  loudly on "already exists" instead of losing anything. The bucket is
  versioned, so every write is undoable.
- **The quiet window is the Remotely Save race mitigation**, not a lock: a
  conflict copy needs both sides to edit one object between two syncs. Raise
  `ORGANIZER_QUIET_MINUTES` if one ever appears.
- **Notes are processed one at a time** — parallel calls to one 27B model
  only queue inside Ollama until they hit the request timeout.
- `ORGANIZER_VAULT_PREFIX` is the remote prefix Remotely Save syncs under,
  if it was given one; empty means the bucket root.

Its pure helpers and write path have a plain-assert test, the one test in
this repo:
`uv run --no-project --python 3.12 --with prefect==3.8.7 python prefect/flows/test_organize_inbox.py`.
````

- [ ] **Step 3: `AGENTS.md`**

On the line containing `` /`s3`/`s3-admin`/`rabbitmq`/`neo4j`/`airflow-*`/`openbao`/`portainer` ``, replace `` `airflow-*` `` with `` `prefect-*` ``.

- [ ] **Step 4: `README.md`**

Replace

```markdown
Airflow: `https://airflow.infra.famillelallier.net` (admin / `AIRFLOW_ADMIN_PASSWORD`;
DAGs go in `airflow/dags/`)
```

with

```markdown
Prefect: `https://prefect.infra.famillelallier.net` (Keycloak realm `infra`,
group `prefect`, then `PREFECT_AUTH_STRING`; flows go in `prefect/flows/`)
```

Replace the whole `## CI: nightly PR validation` section (up to, not including, `## CD: deploying on a push to main`) with:

````markdown
## CI: nightly PR validation

The Prefect flow `pr-validation` (`prefect/flows/pr_validation.py`) runs at
03:00, walks the open non-draft PRs on GitHub, and for each one clones the
head into `/tmp/infra-ci`, renders a throwaway `.env` into it
(`scripts/ci-fake-env.sh`), and runs these checks:

| check | what it catches |
|---|---|
| `prepare workspace` | a PR that breaks `ci-fake-env.sh` itself |
| `check-env` | a new `.env.example` key that nothing else would notice until a container died on its own config |
| `json/yaml` | a broken Grafana dashboard or Keycloak realm — Grafana boots fine and is just missing it |
| `shellcheck` | `scripts/*.sh`, `postgres/initdb/*.sh` |
| `compose config` | an unsatisfied `${VAR:?}`, a malformed service — both kill a deploy before any container starts |
| `nginx -t` | a typo in a new vhost. Every `make up` force-recreates nginx, so this one takes down *all* ingress at deploy time |
| `promtool` | `prometheus.yml` plus its `file_sd` target files |

It posts one comment per PR and updates it on the next run rather than
stacking a new one. A failing check fails that PR's mapped task, so the
Prefect UI shows which PR is red without opening GitHub.

Setup is one Secret block: in `https://prefect.infra.famillelallier.net`,
**Blocks → Secret**, name `infra-ci-github-token`, value a PAT with
`pull_requests:write`. It is a Secret block rather than a `.env` key for the
same reason `PORTAINER_API_KEY` lives in `.portainer.env`: `.env` goes to
containers wholesale and to Portainer as the stack env, and this token can
write to GitHub.

Two caveats worth knowing before relying on it. The checks run as *sibling*
containers through the Docker socket, which is mounted on `prefect-flows`
only — that socket is root on the daemon, which is why the Prefect API
requires `PREFECT_AUTH_STRING`. And a 03:00 schedule does not fire on a
sleeping Mac: either `sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00`, or
move the schedule. `CLAUDE.md` ("Prefect: pipelines") has the rest, including
the `organize-inbox` flow.
````

- [ ] **Step 5: Run the check to verify it passes**

Run: `git grep -n -i airflow -- CLAUDE.md AGENTS.md README.md`
Expected: no output (exit 1).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md AGENTS.md README.md
git commit -m "docs(prefect): replace the Airflow documentation

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Cutover and acceptance (operator, on the deploy host)

Not for a subagent: this needs the live stack, Keycloak admin, and a merge.
**The secrets go in before the merge** — a push to main runs `deploy.yml`,
which renders `.env` from the vault and runs `check-env`; a vault without the
Prefect keys fails that deploy on the new `:?` guards.

**Files:** none in the repo (host `.env`, vault, Keycloak, Prefect UI).

- [ ] **Step 1: Open the PR, and let Airflow validate it one last time**

```bash
git push -u origin feat/prefect
gh pr create --title "Replace Airflow with Prefect; first AI pipeline" --body-file - <<'EOF'
Implements docs/superpowers/specs/2026-09-27-prefect-orchestrator-design.md.
Cutover (secrets before merge): docs/superpowers/plans/2026-09-27-prefect-orchestrator.md, Task 6.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

In `https://airflow.infra.famillelallier.net`, unpause and trigger `infra_pr_validation`. Expected: the PR gets a ✅ comment — `nginx -t`, `compose config` and `check-env` run against this branch's config in the real images, which the offline preflight could not do.

- [ ] **Step 2: Check the bucket layout**

In `https://s3-admin.infra.famillelallier.net`, open bucket `obsidian`. If the vault's folders (and `Inbox/`) sit at the root, `ORGANIZER_VAULT_PREFIX` stays empty; if under a prefix, note it (with a trailing `/`). Create `Inbox/` in the vault if it does not exist yet.

- [ ] **Step 3: Add the keys to the host `.env` (still on the old main)**

```bash
cd <host checkout>/Infra
{
  echo "PREFECT_DB_PASSWORD=$(openssl rand -hex 16)"
  echo "PREFECT_AUTH_STRING=admin:$(openssl rand -hex 16)"
  echo "PREFECT_S3_SECRET_KEY=$(openssl rand -hex 24)"
  echo "PREFECT_OAUTH_COOKIE_SECRET=$(openssl rand -base64 32 | tr -- '+/' '-_')"
  echo "ORGANIZER_VAULT_PREFIX=<from step 2, or empty>"
} >> .env
```

Append `,prefect` to the `APP_DATABASES=` line in `.env`.

- [ ] **Step 4: Provision the database and the S3 identity**

```bash
make provision-app app=prefect
make s3-provision app=prefect bucket=obsidian
```

Expected: both succeed; the second prints the bucket-scoped identity `prefect`.

- [ ] **Step 5: Create the Keycloak group and client**

```bash
docker compose exec -it keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin   # prompts for KEYCLOAK_ADMIN_PASSWORD
kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc create groups -r infra -s name=prefect
git show origin/feat/prefect:keycloak/realm-import/infra-realm.json \
  | jq '.clients[] | select(.clientId=="prefect")' \
  | kc create clients -r infra -f -
cid="$(kc get clients -r infra -q clientId=prefect --fields id | jq -r '.[0].id')"
kc get "clients/$cid/client-secret" -r infra | jq -r .value     # -> PREFECT_OAUTH_CLIENT_SECRET in .env
uid="$(kc get users -r infra -q email=nicolas.lallier@famillelallier.net | jq -r '.[0].id')"
gid="$(kc get groups -r infra -q search=prefect | jq -r '.[] | select(.name=="prefect") | .id')"
kc update "users/$uid/groups/$gid" -r infra -s realm=infra -s userId="$uid" -s groupId="$gid" -n
```

Put the printed secret into `.env` as `PREFECT_OAUTH_CLIENT_SECRET=<value>`.

- [ ] **Step 6: Seed the vault, then merge**

```bash
make vault-seed
gh pr merge --merge
```

CI deploys (`deploy.yml`). Expected: the run succeeds; `docker ps` shows `prefect-server`, `prefect-flows`, `oauth2-proxy-prefect` and no `airflow-*`. If CI is unavailable: `git pull --ff-only && make up`.

- [ ] **Step 7: Create the Secret block**

`https://prefect.infra.famillelallier.net` → SSO → paste `PREFECT_AUTH_STRING` at the prompt → **Blocks → + → Secret**, name `infra-ci-github-token`, value the PAT with `pull_requests:write`.

- [ ] **Step 8: Acceptance**

Run each; all must hold.

```bash
# API refuses an unauthenticated caller on infra-net
docker run --rm --network infra-net curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://prefect-server:4200/api/deployments/filter            # expect 401
docker compose logs prefect-flows | grep -E "nightly|every-15m"         # both deployments registered
```

- A user outside group `prefect` is refused by oauth2-proxy (403); a member passes SSO and then the password prompt.
- **Deployments** shows `pr-validation/nightly` (cron 03:00 America/Toronto) and `organize-inbox/every-15m`.
- **Quick run** of `pr-validation/nightly`: every open PR gets its comment updated, footer "Posté par le flow Prefect `pr-validation`".
- Drop a note `Inbox/prefect-acceptance.md` in the vault, wait ≥ 10 minutes plus one sync and one 15-minute tick: it lands in an existing top-level folder with `tags`, `summary`, `organized_at`; the bucket still holds a version of the deleted `Inbox/prefect-acceptance.md`.

- [ ] **Step 9: After one green nightly run — retire Airflow's leftovers**

```bash
make psql    # then:
#   DROP DATABASE airflow;
#   DROP ROLE airflow;
make vault-cli   # then remove the AIRFLOW_* fields from infra/env
                 # (vault-env would otherwise keep appending them to .env)
```
