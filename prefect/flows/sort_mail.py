"""Sort the Gmail inbox: Ollama picks a label, the flow applies it.

Every run: list up to MAX_THREADS inbox threads, newest first; for each, give
the latest message to Ollama and let it pick one of the Gmail labels under
PREFIX (built per run, so it cannot invent one) or "garder". A sorted thread
gets its label and loses INBOX in one threads.modify call; a kept thread gets
the marker label PREFIX + "_garder" and stays in the inbox.

Gmail is the only state: a thread that left the inbox, or carries the marker,
no longer matches the inbox query. Remove the marker by hand to have a thread
sorted again. Nothing is ever deleted, so a wrong label is fixed from Gmail.

Threads, not messages: the inbox is shown by conversation, and a thread stays
visible while any of its messages carries INBOX.

Credentials: the Prefect Secret block `gmail-sorter-oauth`, JSON
{client_id, client_secret, refresh_token}, written by scripts/gmail-oauth.py.
"""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from typing import Any

from prefect import flow, task

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://192.168.2.40:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.8:27b-mlx")
PREFIX = os.environ.get("SORTER_LABEL_PREFIX", "Tri/")
MAX_THREADS = int(os.environ.get("SORTER_MAX_THREADS", "20"))
KEEP = "garder"
# ponytail: the model sees this many characters of headers + body; raise it
# if long emails come back misfiled.
MAX_CHARS = 8000
GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SECRET_BLOCK = "gmail-sorter-oauth"

SYSTEM_PROMPT = (
    "You sort emails into Gmail labels. Reply with JSON only: the single "
    "category the email belongs to, chosen from this list: {categories}. "
    'Answer "garder" if the email awaits a reply or a personal action from '
    "its recipient, or if no category clearly fits. Add a one-sentence reason."
)


class TokenRevoked(RuntimeError):
    """The refresh token no longer works; only a human can fix that."""


# --------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------


def marker_label(prefix: str = PREFIX) -> str:
    return prefix + "_garder"


def categories(labels: list[dict[str, Any]], prefix: str = PREFIX) -> dict[str, str]:
    """name -> id of the user labels under prefix, minus those whose remainder
    starts with "_" (the marker, and any other label kept out of the enum)."""
    return {
        label["name"]: label["id"]
        for label in labels
        if label.get("type") == "user"
        and label["name"].startswith(prefix)
        and label["name"][len(prefix):][:1] not in ("", "_")
    }


def inbox_query(prefix: str = PREFIX) -> str:
    """Gmail search spells "/" and spaces in a label name as "-"."""
    marker = re.sub(r"[/ ]", "-", marker_label(prefix)).lower()
    return f"in:inbox -label:{marker}"


def reply_schema(names: list[str]) -> dict[str, Any]:
    """Ollama constrains decoding to this; the enum is built per run."""
    return {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": [*names, KEEP]},
            "reason": {"type": "string"},
        },
        "required": ["category", "reason"],
    }


def parse_reply(content: str, names: list[str]) -> dict[str, str]:
    """Validate anyway: the schema is a decoding hint, and this is the last
    check before a label id is looked up from the reply."""
    data = json.loads(content)  # JSONDecodeError is a ValueError
    if not isinstance(data, dict):
        raise ValueError(f"reply is not an object: {content[:200]}")
    category, reason = data.get("category"), data.get("reason")
    if category not in (*names, KEEP):
        raise ValueError(f"model picked unknown category {category!r}")
    if not isinstance(reason, str) or not reason.strip():
        raise ValueError("empty reason")
    return {"category": category, "reason": reason.strip()}


class _Text(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def html_to_text(html: str) -> str:
    parser = _Text()
    parser.feed(html)
    parser.close()
    return " ".join(" ".join(parser.parts).split())


def _headers(part: dict[str, Any]) -> dict[str, str]:
    return {h["name"].lower(): h["value"] for h in part.get("headers", [])}


def _decode(part: dict[str, Any]) -> str:
    """body.data is base64url, often unpadded, in the part's own charset."""
    data = part["body"]["data"]
    raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    match = re.search(r'charset="?([\w.:-]+)', _headers(part).get("content-type", ""), re.I)
    try:
        return raw.decode(match.group(1) if match else "utf-8", "replace")
    except LookupError:  # a charset Python does not know
        return raw.decode("utf-8", "replace")


def _walk(part: dict[str, Any]):
    yield part
    for sub in part.get("parts") or []:
        yield from _walk(sub)


def header(message: dict[str, Any], name: str) -> str:
    return _headers(message["payload"]).get(name.lower(), "")


def latest_message(thread: dict[str, Any]) -> dict[str, Any]:
    """The last message that is not an unsent draft."""
    sent = [m for m in thread["messages"] if "DRAFT" not in m.get("labelIds", [])]
    return (sent or thread["messages"])[-1]


def message_text(message: dict[str, Any]) -> str:
    """What the model reads: a few headers, attachment names, then the first
    text/plain part (else the first text/html part, tags stripped)."""
    parts = list(_walk(message["payload"]))

    def first(mime: str) -> dict[str, Any] | None:
        return next(
            (p for p in parts if p.get("mimeType") == mime and not p.get("filename") and p.get("body", {}).get("data")),
            None,
        )

    plain, html = first("text/plain"), first("text/html")
    body = _decode(plain) if plain else html_to_text(_decode(html)) if html else ""
    headers = _headers(message["payload"])
    lines = [f"{name.title()}: {headers.get(name, '')}" for name in ("from", "to", "subject", "date")]
    lines.append(f"List-Unsubscribe: {'yes' if 'list-unsubscribe' in headers else 'no'}")
    attachments = [p["filename"] for p in parts if p.get("filename")]
    if attachments:
        lines.append("Attachments: " + ", ".join(attachments))
    return ("\n".join(lines) + "\n\n" + body)[:MAX_CHARS]


def transient(exc: BaseException) -> bool:
    """Worth retrying? HTTPError is an OSError too, so its code decides first."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code == 429 or exc.code >= 500
    return not isinstance(exc, (ValueError, TokenRevoked))


# --------------------------------------------------------------------------
# I/O
# --------------------------------------------------------------------------


def _request(url: str, *, token: str | None = None, body: Any = None,
             form: dict[str, str] | None = None, timeout: int = 60) -> Any:
    headers, data = {}, None
    if body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode("utf-8"), "application/json"
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def access_token(creds: dict[str, str]) -> str:
    form = {
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
        "refresh_token": creds["refresh_token"],
        "grant_type": "refresh_token",
    }
    try:
        return _request(TOKEN_URL, form=form)["access_token"]
    except urllib.error.HTTPError as exc:
        if exc.code in (400, 401) and b"invalid_grant" in exc.read():
            raise TokenRevoked(
                f"Gmail refused the refresh token: run scripts/gmail-oauth.py and "
                f"paste its output into the {SECRET_BLOCK} Secret block"
            ) from exc
        raise


class Gmail:
    def __init__(self, token: str) -> None:
        self.token = token

    def _call(self, path: str, body: Any = None) -> Any:
        return _request(f"{GMAIL}/{path}", token=self.token, body=body)

    def labels(self) -> list[dict[str, Any]]:
        return self._call("labels").get("labels", [])

    def create_label(self, name: str) -> str:
        return self._call("labels", {"name": name})["id"]

    def inbox_threads(self, query: str, limit: int) -> list[str]:
        qs = urllib.parse.urlencode({"q": query, "maxResults": limit})
        return [t["id"] for t in self._call(f"threads?{qs}").get("threads", [])]

    def thread(self, thread_id: str) -> dict[str, Any]:
        return self._call(f"threads/{thread_id}?format=full")

    def modify(self, thread_id: str, add: list[str], remove: tuple[str, ...] = ()) -> None:
        self._call(f"threads/{thread_id}/modify", {"addLabelIds": list(add), "removeLabelIds": list(remove)})


def _gmail() -> Gmail:
    # One token refresh per call, the way organize_inbox builds one S3 client
    # per task: nothing secret travels in task arguments.
    from prefect.blocks.system import Secret

    creds = Secret.load(SECRET_BLOCK).get()
    return Gmail(access_token(json.loads(creds) if isinstance(creds, str) else creds))


def classify(text: str, names: list[str]) -> dict[str, str]:
    body = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "format": reply_schema(names),
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT.format(categories=", ".join([*names, KEEP]))},
            {"role": "user", "content": text},
        ],
    }
    reply = _request(f"{OLLAMA_URL}/api/chat", body=body, timeout=300)
    return parse_reply(reply["message"]["content"], names)


# --------------------------------------------------------------------------
# Flow
# --------------------------------------------------------------------------


@task
def discover(dry_run: bool) -> tuple[dict[str, str], str | None, list[str]]:
    """(categories, marker label id, inbox thread ids). The marker is created
    before the inbox is listed, so the query's -label: term always names a
    label that exists."""
    gmail = _gmail()
    labels = gmail.labels()
    cats = categories(labels)
    marker = next((lb["id"] for lb in labels if lb["name"] == marker_label()), None)
    # No category means the flow refuses to run: leave the mailbox untouched.
    if marker is None and cats and not dry_run:
        marker = gmail.create_label(marker_label())
    return cats, marker, gmail.inbox_threads(inbox_query(), MAX_THREADS)


def retry_transient(task, task_run, state) -> bool:
    try:
        state.result()
    except Exception as exc:  # noqa: BLE001 - classified below
        return transient(exc)
    return True


@task(retries=2, retry_delay_seconds=30, retry_condition_fn=retry_transient)
def sort_thread(thread_id: str, cats: dict[str, str], marker_id: str | None, dry_run: bool) -> str:
    # ponytail: a thread that fails the same way every run (bad reply at
    # temperature 0) stays at the top of the inbox and takes a MAX_THREADS
    # slot each run; tag such threads with the marker if that ever matters.
    gmail = _gmail()
    thread = gmail.thread(thread_id)
    message = latest_message(thread)
    # Labels belong to messages: a reply to a kept thread arrives without the
    # marker, and the inbox query matches the thread again. Re-mark it rather
    # than let its newest message ("Merci !") get the whole thread archived.
    if marker_id and any(marker_id in m.get("labelIds", []) for m in thread["messages"]):
        print(f'"{header(message, "subject")}" -> {KEEP} (kept earlier)')
        if not dry_run:
            gmail.modify(thread_id, add=[marker_id])
        return KEEP
    reply = classify(message_text(message), sorted(cats))
    print(f'"{header(message, "subject")}" -> {reply["category"]} ({reply["reason"]})')
    if dry_run:
        return reply["category"]
    if reply["category"] == KEEP:
        assert marker_id, "discover() creates the marker whenever dry_run is off"
        gmail.modify(thread_id, add=[marker_id])
    else:
        # One call: labelled and archived together, never half of it.
        gmail.modify(thread_id, add=[cats[reply["category"]]], remove=("INBOX",))
    return reply["category"]


@flow(name="sort-mail", log_prints=True)
def sort_mail(dry_run: bool = False) -> list[Any]:
    cats, marker, threads = discover(dry_run)
    if not cats:
        raise RuntimeError(f"no Gmail label under {PREFIX!r} to sort into")
    if not threads:
        print("inbox: nothing to sort")
        return []
    # One thread at a time: one model on one Mac, shared with organize-inbox.
    return [sort_thread(t, cats, marker, dry_run, return_state=True) for t in threads]
