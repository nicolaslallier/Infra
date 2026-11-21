"""agent-test (agents/agent-test/server.py) against a fake LiteLLM, with the image's own pinned
requirements: its card, and one A2A message/send answered through /v1/chat/completions.

Run: uv run -q --no-project --with-requirements agents/agent-test/requirements.txt python scripts/test_agent_test.py
"""
import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
seen = []


class FakeLiteLLM(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, self.headers.get("Authorization"), body))
        out = json.dumps({"choices": [{"message": {"role": "assistant", "content": "pong"}}]}).encode()
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
os.environ.update(LITELLM_URL=f"http://127.0.0.1:{fake.server_address[1]}", AGENT_TEST_LITELLM_KEY="sk-test",
                  AGENT_TEST_URL=f"http://127.0.0.1:{port}/")
sys.path.insert(0, os.path.join(ROOT, "agents", "agent-test"))
import uvicorn  # noqa: E402

import server  # noqa: E402

threading.Thread(target=uvicorn.Server(uvicorn.Config(server.app(), port=port, log_level="error")).run, daemon=True).start()
BASE = f"http://127.0.0.1:{port}"
for _ in range(100):
    try:
        urllib.request.urlopen(f"{BASE}/health", timeout=1)
        break
    except OSError:
        time.sleep(0.1)


def get(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=10))


def rpc(method, params, version="1.0"):
    req = urllib.request.Request(BASE + "/", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "A2A-Version": version})
    return json.load(urllib.request.urlopen(req, timeout=30))


def test_the_card_names_the_agent_and_its_jsonrpc_endpoint():
    card = get("/.well-known/agent-card.json")
    assert card["name"] == "agent-test", card
    iface = card["supportedInterfaces"][0]
    assert iface["protocolBinding"] == "JSONRPC" and iface["protocolVersion"] == "1.0", iface
    assert iface["url"] == BASE + "/", iface


def test_a_message_is_answered_by_qwen_through_litellm_with_the_agent_key():
    seen.clear()
    out = rpc("SendMessage", {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "ping"}]}})
    assert "error" not in out, out
    assert json.dumps(out).count("pong") == 1, out
    path, auth, body = seen[0]
    assert path == "/v1/chat/completions" and auth == "Bearer sk-test", (path, auth)
    assert body["model"] == "qwen3.8:27b-mlx" and body["messages"] == [{"role": "user", "content": "ping"}], body


def test_the_server_refuses_to_start_without_a_key():
    import subprocess
    env = {**os.environ, "AGENT_TEST_LITELLM_KEY": ""}
    r = subprocess.run([sys.executable, os.path.join(ROOT, "agents", "agent-test", "server.py")], env=env,
                       capture_output=True, text=True, timeout=60)
    assert r.returncode != 0 and "AGENT_TEST_LITELLM_KEY" in r.stderr, r


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
