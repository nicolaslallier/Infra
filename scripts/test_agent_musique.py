"""agent-musique (agents/agent-musique/) against a fake LiteLLM and an in-memory S3, with the image's
own pinned requirements.

Run: uv run -q --no-project --with-requirements agents/agent-musique/requirements.txt python scripts/test_agent_musique.py
"""
import io
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from botocore.exceptions import ClientError

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, "agents", "agent-musique")
VP = "Maison/"
M = "Maison/02 - Domaines/Loisirs/Musique/"
NOW = datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc)
OLD = NOW - timedelta(hours=1)


class FakeS3:
    """The calls disques.py makes, on a dict {key: (bytes, LastModified)}."""

    def __init__(self, data=None):
        self.data = {k: (v, OLD) for k, v in (data or {}).items()}
        self.puts = []

    def _missing(self, op, code):
        raise ClientError({"Error": {"Code": code}}, op)

    def get_object(self, Bucket, Key):  # noqa: N803
        if Key not in self.data:
            self._missing("GetObject", "NoSuchKey")
        return {"Body": io.BytesIO(self.data[Key][0])}

    def head_object(self, Bucket, Key):  # noqa: N803
        if Key not in self.data:
            self._missing("HeadObject", "404")
        return {"LastModified": self.data[Key][1], "ContentLength": len(self.data[Key][0])}

    def put_object(self, Bucket, Key, Body, ContentType=None):  # noqa: N803
        self.puts.append(Key)
        self.data[Key] = (Body, NOW)

    def list_objects_v2(self, Bucket, Prefix, ContinuationToken=None):  # noqa: N803
        return {"Contents": [{"Key": k} for k in sorted(self.data) if k.startswith(Prefix)], "IsTruncated": False}

    def text(self, key):
        return self.data[key][0].decode()


# --- the fake LiteLLM: answers from a script of messages, records each call ---
seen, script = [], []


class FakeLiteLLM(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, self.headers.get("Authorization"), body))
        msg = script.pop(0) if script else {"role": "assistant", "content": "pong"}
        out = json.dumps({"choices": [{"message": msg}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeLiteLLM)
threading.Thread(target=fake.serve_forever, daemon=True).start()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
os.environ.update(LITELLM_URL=f"http://127.0.0.1:{fake.server_address[1]}", AGENT_MUSIQUE_LITELLM_KEY="sk-musique",
                  AGENT_MUSIQUE_TOKEN="t0ken", AGENT_MUSIQUE_S3_SECRET_KEY="s3cret",
                  AGENT_MUSIQUE_URL=f"http://127.0.0.1:{port}/", OBSIDIAN_VAULT_PREFIX=VP)
sys.path.insert(0, AGENT)
import uvicorn  # noqa: E402

import disques  # noqa: E402
import server  # noqa: E402

S3 = FakeS3({M + "Discographie.md": b"| Miles Davis | Kind of Blue | vinyle |\n",
             M + "Miles Davis - Kind of Blue (vinyle).md": b"---\ntype: disque\n---\nPressage 1959\n"})
threading.Thread(target=uvicorn.Server(uvicorn.Config(server.app(S3), port=port, log_level="error")).run,
                 daemon=True).start()
BASE = f"http://127.0.0.1:{port}"
for _ in range(100):
    try:
        urllib.request.urlopen(f"{BASE}/health", timeout=1)
        break
    except OSError:
        time.sleep(0.1)


def req(path, data=None, token="t0ken"):
    h = {"Content-Type": "application/json", "A2A-Version": "1.0"}
    if token:
        h["X-Agent-Token"] = token
    return json.load(urllib.request.urlopen(urllib.request.Request(BASE + path, data, h), timeout=30))


def send(text):
    body = {"jsonrpc": "2.0", "id": 1, "method": "SendMessage",
            "params": {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": text}]}}}
    return req("/", json.dumps(body).encode())


def call(name, **args):
    return {"role": "assistant", "content": None,
            "tool_calls": [{"id": "c1", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}]}


def test_the_card_names_the_agent():
    card = req("/.well-known/agent-card.json")
    assert card["name"] == "agent-musique", card
    assert card["supportedInterfaces"][0]["url"] == BASE + "/", card


def test_without_the_token_it_is_401_but_health_is_open():
    for token in (None, "wrong"):
        for path, data in (("/.well-known/agent-card.json", None), ("/", b"{}")):
            try:
                req(path, data, token=token)
                raise AssertionError(f"{path} answered without the token")
            except urllib.error.HTTPError as e:
                assert e.code == 401, e.code
    assert urllib.request.urlopen(f"{BASE}/health", timeout=5).status == 200


def test_the_server_refuses_to_start_without_each_secret():
    for k in ("AGENT_MUSIQUE_LITELLM_KEY", "AGENT_MUSIQUE_TOKEN", "AGENT_MUSIQUE_S3_SECRET_KEY"):
        r = subprocess.run([sys.executable, os.path.join(AGENT, "server.py")], env={**os.environ, k: ""},
                           capture_output=True, text=True, timeout=60)
        assert r.returncode != 0 and k in r.stderr, (k, r)


def test_the_prefix_guard():
    ok = M + "A - B (CD).md"
    assert disques.cle_ecriture(ok, VP) == ok
    for bad in (M + "../x.md", M + "a/../../x.md", "/" + ok, "Maison/Inbox/a.md", "Maison/02 - Domaines/x.md",
                M + "a.txt", M + ".obsidian/a.md", M + "a//b.md", M + "./a.md", "Autre/" + ok, ok + "x"):
        try:
            disques.cle_ecriture(bad, VP)
            raise AssertionError(f"accepted {bad!r}")
        except ValueError:
            pass
    for bad in ("../x.md", "/etc/passwd", "Inbox/a.md", "02 - Domaines/Loisirs/Musique/../../x.md"):
        try:
            disques.cle_lecture(bad, VP)
            raise AssertionError(f"read {bad!r}")
        except ValueError:
            pass


def test_the_module_never_deletes_or_copies_and_writes_in_one_place():
    src = open(os.path.join(AGENT, "disques.py")).read() + open(os.path.join(AGENT, "server.py")).read()
    assert "delete_object" not in src and "copy_object" not in src
    assert src.count("put_object") == 1
    assert re.search(r"def _ecrire\(.*\n(.*\n){0,2}\s+s3\.put_object\(.*Key=cle_ecriture\(", src), "put not guarded"


def test_the_note_name_is_chosen_by_the_code():
    assert disques.nom_note("AC/DC", "Back: in [Black]?", "vinyle") == "AC DC - Back in Black (vinyle).md"
    assert disques.nom_note("Café", "x", "CD") == "Café - x (CD).md"
    s3 = FakeS3()
    rel, msg = disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="../../etc", titre="x", format="CD")
    assert rel.startswith("02 - Domaines/Loisirs/Musique/") and "/" not in rel[len(disques.MUSIQUE):], rel


def test_a_creation_writes_the_frontmatter_and_the_index():
    s3 = FakeS3()
    rel, msg = disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="Harmonium", titre="L'Heptade",
                                   format="vinyle", annee="1976", label="CBS", etat="VG+", notes="double")
    assert msg == "note créée" and rel == disques.MUSIQUE + "Harmonium - L'Heptade (vinyle).md"
    fm = disques.lire_frontmatter(s3.text(VP + rel))
    assert fm == {"type": "disque", "tags": "[musique, disque]", "source": "claude", "artiste": "Harmonium",
                  "titre": "L'Heptade", "format": "vinyle", "annee": "1976", "label": "CBS"}, fm
    assert "## Notes\n- 2026-11-21 : état : VG+; double\n" in s3.text(VP + rel)
    index = s3.text(M + "Discographie.md")
    assert "ne pas éditer" in index and "| Harmonium | L'Heptade | vinyle | 1976 | CBS |" in index, index
    assert f"[[{rel[:-3]}]]" in index
    disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="Beau Dommage", titre="Beau Dommage", format="CD")
    index = s3.text(M + "Discographie.md")
    assert index.index("Beau Dommage") < index.index("Harmonium"), index  # regenerated, sorted


ORIGINAL = ('---\ntype: disque\ntags: [musique, disque]\nheure: 12:30\nartiste: "Harmonium"\nannee: "1975"\n'
            'perso: NO\n---\n# Harmonium\n\nMon texte à moi.\n\n## Notes\n- 2020-01-01 : acheté\n\n## Autre\nfin\n')


def test_a_creation_on_an_existing_note_is_an_update_that_keeps_the_rest_byte_for_byte():
    key = M + "Harmonium - L'Heptade (vinyle).md"
    s3 = FakeS3({key: ORIGINAL.encode()})
    rel, msg = disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="Harmonium", titre="L'Heptade",
                                   format="vinyle", annee="1976", label="CBS", notes="rejoué")
    assert msg == "note existante mise à jour", msg
    expected = (ORIGINAL.replace('annee: "1975"', 'annee: "1976"')
                .replace("perso: NO\n", 'perso: NO\ntitre: "L\'Heptade"\nformat: "vinyle"\nlabel: "CBS"\n')
                .replace("- 2020-01-01 : acheté\n", "- 2020-01-01 : acheté\n- 2026-11-21 : rejoué\n"))
    assert s3.text(key) == expected, s3.text(key)


def test_an_update_inside_the_quiet_window_is_refused():
    key = M + "Harmonium - L'Heptade (vinyle).md"
    s3 = FakeS3({key: ORIGINAL.encode()})
    s3.data[key] = (ORIGINAL.encode(), NOW - timedelta(minutes=9))
    rel, msg = disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="Harmonium", titre="L'Heptade", format="vinyle")
    assert msg.startswith("refusé") and s3.puts == [], (msg, s3.puts)


def test_the_loop_reads_cites_only_what_it_read_and_strips_a_made_up_sources_line():
    s3 = FakeS3({M + "Discographie.md": b"INDEX-MARK", M + "A - B (CD).md": b"note A", M + "C - D (CD).md": b"note C"})
    replies = [call("lire_disque", chemin="[[02 - Domaines/Loisirs/Musique/A - B (CD)]]"),
               call("lire_disque", chemin="Inbox/secret.md"),
               {"role": "assistant", "content": "Dans ta collection : A.\nSources : C - D (CD).md"}]
    calls = []

    def llm(messages, tools):
        calls.append(json.loads(json.dumps(messages)))
        return replies.pop(0)
    out = disques.repondre(s3, "obsidian", VP, llm, "j'ai A ?", NOW)
    assert "INDEX-MARK" in calls[0][0]["content"] and calls[0][0]["role"] == "system"
    assert "pas dans ta collection" in calls[0][0]["content"]
    assert "erreur" in calls[2][-1]["content"]  # outside the folder: refused
    assert out == ("Dans ta collection : A.\n\nSources : 02 - Domaines/Loisirs/Musique/Discographie.md, "
                   "02 - Domaines/Loisirs/Musique/A - B (CD).md"), out


def test_the_loop_is_bounded_to_six_model_calls():
    n = []

    def llm(messages, tools):
        n.append(1)
        return call("chercher", texte="x")
    out = disques.repondre(FakeS3(), "obsidian", VP, llm, "boucle", NOW)
    assert len(n) == 6 and "6 tours" in out, (len(n), out)


def test_a_message_goes_to_qwen_through_litellm_with_the_agent_key_at_temperature_zero():
    seen.clear()
    script[:] = [call("lire_disque", chemin="02 - Domaines/Loisirs/Musique/Miles Davis - Kind of Blue (vinyle).md"),
                 {"role": "assistant", "content": "Tu l'as en vinyle."}]
    out = json.dumps(send("Kind of Blue ?"), ensure_ascii=False)
    assert "Tu l'as en vinyle." in out and "Kind of Blue (vinyle).md" in out and "Sources : " in out, out
    assert len(seen) == 2
    for path, auth, body in seen:
        assert path == "/v1/chat/completions" and auth == "Bearer sk-musique", (path, auth)
        assert body["model"] == "gemma4:26b-a4b-it-qat" and body["temperature"] == 0 and body["tools"], body
    assert "Miles Davis | Kind of Blue" in seen[0][2]["messages"][0]["content"]
    assert "Pressage 1959" in seen[1][2]["messages"][-1]["content"]



def refused(fn, needle):
    try:
        fn()
    except ValueError as e:
        assert needle in str(e), e
        return
    raise AssertionError("not refused")


def test_an_update_never_truncates_or_alters_a_note():
    key = M + "A - B (CD).md"
    cases = {"octets": ORIGINAL.encode() + b"x" * disques.MAX_READ_BYTES,
             "UTF-8": ORIGINAL.encode() + b"\xff\xfe",
             "CRLF": ORIGINAL.replace("\n", "\r\n").encode(),
             "plusieurs lignes": ORIGINAL.replace('annee: "1975"', "annee:\n  - 1975").encode(),
             "plusieurs lignes ": ORIGINAL.replace('annee: "1975"', "annee: >\n  1975").encode()}
    for needle, body in cases.items():
        s3 = FakeS3({key: body})
        refused(lambda: disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="A", titre="B", format="CD",
                                            annee="1976"), needle.strip())
        assert s3.puts == [] and s3.data[key][0] == body, needle


def test_a_hand_written_discographie_is_never_overwritten():
    hand = b"# Ma discographie a moi\n"
    s3 = FakeS3({M + "Discographie.md": hand})
    rel, msg = disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="A", titre="B", format="CD")
    assert "note créée" in msg and "NON régénéré" in msg, msg
    assert s3.data[M + "Discographie.md"][0] == hand and s3.puts == [VP + rel]
    disques.regenerer_index(FakeS3(), "obsidian", VP)  # absent: created
    s3 = FakeS3()
    disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="A", titre="B", format="CD")
    disques.enregistrer(s3, "obsidian", VP, NOW, 10, artiste="C", titre="D", format="CD")  # ours: rewritten
    assert "| C | D |" in s3.text(M + "Discographie.md")


def test_the_scan_limit_is_said_in_the_index_and_in_chercher():
    s3 = FakeS3({M + f"n{i}.md": b"---\ntype: disque\n---\nzz\n" for i in range(3)})
    old, disques.MAX_SCAN = disques.MAX_SCAN, 2
    try:
        disques.regenerer_index(s3, "obsidian", VP)
        assert "Index incomplet" in s3.text(M + "Discographie.md")
        found, truncated = disques.chercher(s3, "obsidian", VP, "zz")
        assert len(found) == 2 and truncated
    finally:
        disques.MAX_SCAN = old


def test_bad_tool_arguments_go_back_to_the_model():
    replies = [{"role": "assistant", "tool_calls": [
                   {"id": "1", "function": {"name": "lire_disque", "arguments": "[1]"}},
                   {"id": "2", "function": {"name": "enregistrer_disque",
                                            "arguments": json.dumps({"artiste": 1, "titre": "x", "format": "CD"})}},
                   {"id": "3", "function": {"name": "chercher", "arguments": "{}"}}]},
               {"role": "assistant", "content": "ok"}]
    seen_msgs = []

    def llm(messages, tools):
        seen_msgs.append(messages)
        return replies.pop(0)
    s3 = FakeS3()
    assert disques.repondre(s3, "obsidian", VP, llm, "x", NOW) == "ok"
    tools = [m for m in seen_msgs[-1] if m["role"] == "tool"]
    assert len(tools) == 3 and all(t["content"].startswith("erreur") for t in tools), tools
    assert s3.puts == []


def test_a_write_during_six_exhausted_rounds_is_said():
    out = disques.repondre(FakeS3(), "obsidian", VP,
                           lambda m, t: call("enregistrer_disque", artiste="A", titre="B", format="CD"), "x", NOW)
    assert "6 tours" in out and "enregistré" in out and "A - B (CD).md" in out, out


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
