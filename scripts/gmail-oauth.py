#!/usr/bin/env python3
"""Get a Gmail refresh token for the sort-mail Prefect flow. Run once, on a
machine with a browser; stdlib only.

  python3 scripts/gmail-oauth.py path/to/client_secret.json

client_secret.json is the "Desktop app" OAuth client downloaded from Google
Cloud Console (APIs & Services -> Credentials). The consent screen must be
Internal: an External app in Testing mode has its refresh tokens revoked
after 7 days.

Prints one JSON line. Paste it as the value of the Prefect Secret block
`gmail-sorter-oauth` (Prefect UI -> Blocks -> Secret). It grants read and
label access to the whole mailbox: do not save it anywhere else.
"""

from __future__ import annotations

import json
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

SCOPE = "https://www.googleapis.com/auth/gmail.modify"
# Filled by the one callback that carries Google's answer (code or error).
CALLBACK: dict[str, str] = {}


class _Callback(BaseHTTPRequestHandler):
    def do_GET(self):
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
        if "code" in query or "error" in query:
            CALLBACK.update(query)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write("Done, you can close this tab.".encode())

    def log_message(self, format, *args):
        pass


def main(path: str) -> None:
    with open(path, encoding="utf-8") as f:
        client = json.load(f)["installed"]
    # Loopback redirect on a free port: allowed for Desktop clients without
    # registering it in the console.
    server = HTTPServer(("127.0.0.1", 0), _Callback)
    redirect = f"http://127.0.0.1:{server.server_port}"
    state = secrets.token_urlsafe(16)
    url = client["auth_uri"] + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"],
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": SCOPE,
        # offline + consent: Google only returns a refresh token on a fresh consent.
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
    })
    print(f"Opening the browser. If it does not open, visit:\n{url}\n", file=sys.stderr)
    webbrowser.open(url)
    while not CALLBACK:
        server.handle_request()  # a stray /favicon.ico request is just skipped
    query = CALLBACK
    if query.get("state") != state:
        sys.exit("state mismatch: ignoring this callback")
    if "code" not in query:
        sys.exit(f"Google refused: {query.get('error')}")
    form = urllib.parse.urlencode({
        "code": query["code"],
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "redirect_uri": redirect,
        "grant_type": "authorization_code",
    }).encode()
    with urllib.request.urlopen(urllib.request.Request(client["token_uri"], data=form), timeout=30) as resp:
        token = json.load(resp)
    if "refresh_token" not in token:
        sys.exit("no refresh_token in Google's reply; revoke the app at myaccount.google.com/permissions and retry")
    print(json.dumps({
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "refresh_token": token["refresh_token"],
    }))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
