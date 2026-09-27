"""Plain-assert checks for sort_mail: the pure helpers, plus sort_thread and
the flow against an in-memory Gmail stand-in.

Run from the repo root:
  uv run --no-project --python 3.12 --with prefect==3.8.7 \
    python prefect/flows/test_sort_mail.py
"""

from __future__ import annotations

import base64
import io
import json
import urllib.error

import sort_mail as sm


def _b64(text: str, charset: str = "utf-8") -> str:
    # Gmail sends base64url without padding.
    return base64.urlsafe_b64encode(text.encode(charset)).decode().rstrip("=")


def _part(mime: str, text: str, charset: str = "utf-8", filename: str = "") -> dict:
    return {
        "mimeType": mime,
        "filename": filename,
        "headers": [{"name": "Content-Type", "value": f'{mime}; charset="{charset}"'}],
        "body": {"data": _b64(text, charset)},
    }


def _message(payload: dict, headers: dict | None = None, label_ids: list | None = None) -> dict:
    payload = dict(payload)
    payload["headers"] = payload.get("headers", []) + [
        {"name": k, "value": v} for k, v in ({"Subject": "Hi", "From": "a@b.c"} if headers is None else headers).items()
    ]
    return {"id": "m", "labelIds": label_ids or ["INBOX"], "payload": payload}


LABELS = [
    {"id": "INBOX", "name": "INBOX", "type": "system"},
    {"id": "L1", "name": "Tri/Factures", "type": "user"},
    {"id": "L2", "name": "Tri/Infolettres", "type": "user"},
    {"id": "L3", "name": "Tri/_garder", "type": "user"},
    {"id": "L4", "name": "Tri/", "type": "user"},
    {"id": "L5", "name": "Personnel", "type": "user"},
    {"id": "L6", "name": "Trips", "type": "user"},
]


# --------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------


def test_categories_prefix_and_underscore():
    assert sm.categories(LABELS, "Tri/") == {"Tri/Factures": "L1", "Tri/Infolettres": "L2"}


def test_inbox_query_excludes_marker():
    assert sm.inbox_query("Tri/") == "in:inbox -label:tri-_garder"
    assert sm.inbox_query("Mail Sort/") == "in:inbox -label:mail-sort-_garder"


def test_reply_schema_enum_has_keep():
    enum = sm.reply_schema(["Tri/A"])["properties"]["category"]["enum"]
    assert enum == ["Tri/A", "garder"]


def test_parse_reply_accepts():
    reply = sm.parse_reply('{"category": "garder", "reason": " awaits a reply "}', ["Tri/A"])
    assert reply == {"category": "garder", "reason": "awaits a reply"}


def test_parse_reply_rejects():
    for content in ('["Tri/A"]', '{"category": "Tri/B", "reason": "x"}', '{"category": "Tri/A", "reason": " "}', "nope"):
        try:
            sm.parse_reply(content, ["Tri/A"])
        except ValueError:
            continue
        raise AssertionError(f"accepted {content!r}")


def test_message_text_plain_and_headers():
    msg = _message(
        {"mimeType": "multipart/mixed", "parts": [
            {"mimeType": "multipart/alternative", "parts": [
                _part("text/html", "<p>html version</p>"),
                _part("text/plain", "plain version é"),
            ]},
            _part("application/pdf", "%PDF", filename="facture.pdf"),
        ]},
        headers={"SUBJECT": "Votre facture", "From": "shop@x.com", "List-Unsubscribe": "<mailto:u@x.com>"},
    )
    text = sm.message_text(msg)
    assert "Subject: Votre facture" in text
    assert "List-Unsubscribe: yes" in text
    assert "Attachments: facture.pdf" in text
    assert text.endswith("plain version é")
    assert "html version" not in text


def test_message_text_html_only_strips_tags_and_style():
    msg = _message(_part("text/html", "<style>p{color:red}</style><p>Bonjour <b>Nicolas</b></p>"))
    text = sm.message_text(msg)
    assert text.endswith("Bonjour Nicolas"), text
    assert "color" not in text
    assert "List-Unsubscribe: no" in text


def test_message_text_latin1_body():
    msg = _message(_part("text/plain", "Reçu de paiement", charset="iso-8859-1"))
    assert sm.message_text(msg).endswith("Reçu de paiement")


def test_message_text_unknown_charset_falls_back():
    part = _part("text/plain", "ok")
    part["headers"] = [{"name": "Content-Type", "value": "text/plain; charset=x-nonsense"}]
    msg = _message(part)
    assert sm.message_text(msg).endswith("ok")


def test_message_text_no_body_still_classifiable():
    msg = _message(_part("text/calendar", "BEGIN:VCALENDAR", filename="invite.ics"))
    text = sm.message_text(msg)
    assert "Subject: Hi" in text and "Attachments: invite.ics" in text


def test_message_text_is_cut():
    msg = _message(_part("text/plain", "x" * (sm.MAX_CHARS * 2)))
    assert len(sm.message_text(msg)) == sm.MAX_CHARS


def test_header_missing_is_empty():
    assert sm.header(_message(_part("text/plain", "b"), headers={}), "subject") == ""


def test_latest_message_skips_drafts():
    sent, draft = {"id": "1", "labelIds": ["INBOX"]}, {"id": "2", "labelIds": ["DRAFT"]}
    assert sm.latest_message({"messages": [sent, draft]}) is sent
    assert sm.latest_message({"messages": [draft]}) is draft


def _http(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(b""))


def test_transient():
    assert sm.transient(_http(429)) and sm.transient(_http(503))
    assert sm.transient(urllib.error.URLError("refused")) and sm.transient(TimeoutError())
    assert not sm.transient(_http(404)) and not sm.transient(_http(400))
    assert not sm.transient(ValueError("bad reply"))
    assert not sm.transient(json.JSONDecodeError("x", "", 0))
    assert not sm.transient(sm.TokenRevoked("revoked"))


def test_access_token_revoked():
    def refuse(url, **kwargs):
        raise urllib.error.HTTPError(url, 400, "Bad Request", {}, io.BytesIO(b'{"error": "invalid_grant"}'))

    real, sm._request = sm._request, refuse
    try:
        sm.access_token({"client_id": "i", "client_secret": "s", "refresh_token": "r"})
    except sm.TokenRevoked as exc:
        assert "gmail-oauth.py" in str(exc)
    else:
        raise AssertionError("no TokenRevoked")
    finally:
        sm._request = real


# --------------------------------------------------------------------------
# sort_thread / flow against a fake Gmail
# --------------------------------------------------------------------------


class FakeGmail:
    def __init__(self, labels=LABELS, threads=("t1",), messages=None):
        self._labels = [dict(lb) for lb in labels]
        self._threads = list(threads)
        self._messages = messages or [_message(_part("text/plain", "body"))]
        self.modified: list[tuple] = []
        self.created: list[str] = []
        self.queries: list[str] = []

    def labels(self):
        return self._labels

    def create_label(self, name):
        self.created.append(name)
        self._labels.append({"id": "NEW", "name": name, "type": "user"})
        return "NEW"

    def inbox_threads(self, query, limit):
        self.queries.append(query)
        return self._threads[:limit]

    def thread(self, thread_id):
        return {"id": thread_id, "messages": self._messages}

    def modify(self, thread_id, add, remove=()):
        self.modified.append((thread_id, list(add), list(remove)))


def _wire(gmail: FakeGmail, category: str = "Tri/Factures") -> None:
    sm._gmail = lambda: gmail
    sm.classify = lambda text, names: {"category": category, "reason": "because"}


CATS = {"Tri/Factures": "L1", "Tri/Infolettres": "L2"}


def test_sort_thread_labels_and_archives_in_one_call():
    gmail = FakeGmail()
    _wire(gmail)
    assert sm.sort_thread.fn("t1", CATS, "L3", False) == "Tri/Factures"
    assert gmail.modified == [("t1", ["L1"], ["INBOX"])]


def test_sort_thread_keep_adds_marker_only():
    gmail = FakeGmail()
    _wire(gmail, "garder")
    sm.sort_thread.fn("t1", CATS, "L3", False)
    assert gmail.modified == [("t1", ["L3"], [])]


def test_sort_thread_dry_run_touches_nothing():
    gmail = FakeGmail()
    _wire(gmail)
    assert sm.sort_thread.fn("t1", CATS, None, True) == "Tri/Factures"
    assert gmail.modified == []


def test_discover_creates_marker_unless_dry_run():
    no_marker = [lb for lb in LABELS if lb["name"] != "Tri/_garder"]
    gmail = FakeGmail(labels=no_marker)
    _wire(gmail)
    assert sm.discover.fn(True)[1] is None and gmail.created == []
    cats, marker, threads = sm.discover.fn(False)
    assert (marker, gmail.created, threads) == ("NEW", ["Tri/_garder"], ["t1"])
    assert cats == CATS
    assert gmail.queries[-1] == "in:inbox -label:tri-_garder"


def test_reply_to_kept_thread_stays_kept():
    # Labels belong to messages: a reply to a kept thread arrives without the
    # marker, so the inbox query matches the thread again. It must be re-marked,
    # never re-classified (a "Merci !" would otherwise get it archived).
    kept = _message(_part("text/plain", "please call me"), label_ids=["INBOX", "L3"])
    reply = _message(_part("text/plain", "Merci !"), label_ids=["INBOX"])
    gmail = FakeGmail(messages=[kept, reply])
    _wire(gmail)
    sm.classify = lambda text, names: (_ for _ in ()).throw(AssertionError("classified a kept thread"))
    assert sm.sort_thread.fn("t1", CATS, "L3", False) == "garder"
    assert gmail.modified == [("t1", ["L3"], [])]
    gmail.modified.clear()
    assert sm.sort_thread.fn("t1", CATS, "L3", True) == "garder"
    assert gmail.modified == []


def test_discover_without_categories_creates_nothing():
    only_other = [lb for lb in LABELS if not lb["name"].startswith("Tri/")]
    gmail = FakeGmail(labels=only_other)
    _wire(gmail)
    cats, marker, _ = sm.discover.fn(False)
    assert (cats, marker, gmail.created) == ({}, None, [])


def test_flow_refuses_without_categories():
    _wire(FakeGmail(labels=[lb for lb in LABELS if not lb["name"].startswith("Tri/F")
                            and not lb["name"].startswith("Tri/I")]))
    try:
        sm.sort_mail.fn(dry_run=True)
    except RuntimeError as exc:
        assert "Tri/" in str(exc)
    else:
        raise AssertionError("flow ran with no category")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
