"""agent-musique: Nicolas's record collection, answered from his Obsidian vault (disques.py).

LiteLLM is the only intended caller: it sends `X-Agent-Token` (static_headers in
litellm/config.yaml), and every request but /health without it gets 401, because infra-net is
shared and this agent can write to the vault. The model is qwen3.8 through LiteLLM with the
agent's own key (team `agents`, local models only). Who may call it is decided in LiteLLM
(litellm/mcp_policy.yaml, `agents:`).
"""
import asyncio
import hmac
import os
from datetime import datetime
from zoneinfo import ZoneInfo

import boto3
import disques
import httpx
import uvicorn
from a2a.helpers.proto_helpers import new_text_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface
from botocore.config import Config
from starlette.applications import Starlette
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

MODEL = "qwen3.8:27b-mlx"
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm:4000").rstrip("/")
PUBLIC_URL = os.environ.get("AGENT_MUSIQUE_URL", "http://agent-musique:8000/")
KEY = os.environ.get("AGENT_MUSIQUE_LITELLM_KEY", "")
TOKEN = os.environ.get("AGENT_MUSIQUE_TOKEN", "")
S3_SECRET = os.environ.get("AGENT_MUSIQUE_S3_SECRET_KEY", "")
BUCKET = os.environ.get("OBSIDIAN_BUCKET", "obsidian")
VAULT_PREFIX = os.environ.get("OBSIDIAN_VAULT_PREFIX", "")
QUIET = int(os.environ.get("AGENT_MUSIQUE_QUIET_MINUTES", "10"))

CARD = AgentCard(
    name="agent-musique",
    description="Ta collection de disques, depuis ton coffre Obsidian : répond et enregistre (qwen3.8, local).",
    version="1",
    supported_interfaces=[AgentInterface(url=PUBLIC_URL, protocol_binding="JSONRPC", protocol_version="1.0")],
    capabilities=AgentCapabilities(streaming=False),
    default_input_modes=["text"],
    default_output_modes=["text"],
)


class RequireToken:
    """ASGI middleware: every HTTP request except /health needs `X-Agent-Token: <token>` (from mcp/obsidian)."""

    def __init__(self, app, token: str):
        self.app, self._token = app, token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"] != "/health":
            got = dict(scope["headers"]).get(b"x-agent-token", b"")
            if not hmac.compare_digest(got, self._token):
                await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


def llm(messages, tools):
    r = httpx.post(f"{LITELLM_URL}/v1/chat/completions", headers={"Authorization": f"Bearer {KEY}"}, timeout=600,
                   json={"model": MODEL, "messages": messages, "tools": tools, "temperature": 0})
    r.raise_for_status()
    return r.json()["choices"][0]["message"]


class MusiqueExecutor(AgentExecutor):
    def __init__(self, s3):
        self.s3 = s3

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        text = await asyncio.to_thread(disques.repondre, self.s3, BUCKET, VAULT_PREFIX, llm,
                                       context.get_user_input(), datetime.now(ZoneInfo("America/Montreal")), QUIET)
        await event_queue.enqueue_event(new_text_message(text, context_id=context.context_id, task_id=context.task_id))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("agent-musique answers in one shot; nothing to cancel")


async def health(_):
    return PlainTextResponse("ok")


def app(s3) -> RequireToken:
    if not TOKEN:
        raise ValueError("AGENT_MUSIQUE_TOKEN must be set: infra-net is shared, the agent must not be open")
    handler = DefaultRequestHandler(MusiqueExecutor(s3), InMemoryTaskStore(), CARD)
    routes = create_agent_card_routes(CARD) + create_jsonrpc_routes(handler, "/") + [Route("/health", health)]
    return RequireToken(Starlette(routes=routes), TOKEN)


if __name__ == "__main__":
    for name, value in (("AGENT_MUSIQUE_LITELLM_KEY", KEY), ("AGENT_MUSIQUE_TOKEN", TOKEN),
                        ("AGENT_MUSIQUE_S3_SECRET_KEY", S3_SECRET)):
        if not value:
            raise SystemExit(f"{name} is empty: refusing to start")
    client = boto3.client(
        "s3", endpoint_url=os.environ.get("S3_ENDPOINT", "http://s3:8333"),
        aws_access_key_id=os.environ.get("AGENT_MUSIQUE_S3_ACCESS_KEY", "agent-musique"),
        aws_secret_access_key=S3_SECRET, region_name="us-east-1", config=Config(s3={"addressing_style": "path"}),
    )
    uvicorn.run(app(client), host="0.0.0.0", port=8000)
