"""agent-test: the first A2A agent behind LiteLLM. It answers each message with qwen3.8 (local).

LiteLLM is the only caller that matters: it reads this agent's card, then posts the A2A
JSON-RPC message here (http://agent-test:8000/). The agent asks LiteLLM's own
/v1/chat/completions with its dedicated key (team `agents`, local models only), so its
answer never leaves the Macs. Who may call the agent is decided in LiteLLM, by the
cloud_pii gate (litellm/mcp_policy.yaml, `agents:`).
"""
import os

import httpx
import uvicorn
from a2a.helpers.proto_helpers import new_text_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route

MODEL = "qwen3.8:27b-mlx"
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm:4000").rstrip("/")
PUBLIC_URL = os.environ.get("AGENT_TEST_URL", "http://agent-test:8000/")
KEY = os.environ.get("AGENT_TEST_LITELLM_KEY", "")

CARD = AgentCard(
    name="agent-test",
    description="Test agent: answers with qwen3.8 (local model).",
    version="1",
    supported_interfaces=[AgentInterface(url=PUBLIC_URL, protocol_binding="JSONRPC", protocol_version="1.0")],
    capabilities=AgentCapabilities(streaming=False),
    default_input_modes=["text"],
    default_output_modes=["text"],
)


class QwenExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        async with httpx.AsyncClient(timeout=600) as c:
            r = await c.post(f"{LITELLM_URL}/v1/chat/completions",
                             headers={"Authorization": f"Bearer {KEY}"},
                             json={"model": MODEL, "messages": [{"role": "user", "content": context.get_user_input()}]})
            r.raise_for_status()
        text = r.json()["choices"][0]["message"]["content"] or ""
        await event_queue.enqueue_event(new_text_message(text, context_id=context.context_id, task_id=context.task_id))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("agent-test answers in one shot; nothing to cancel")


async def health(_):
    return PlainTextResponse("ok")


def app() -> Starlette:
    # ponytail: no token from LiteLLM to the agent; infra-net callers can reach it directly, but it
    # only spends its own local-only key. Add a shared bearer (like OBSIDIAN_MCP_TOKEN) if it ever
    # gets a tool or a cloud model.
    handler = DefaultRequestHandler(QwenExecutor(), InMemoryTaskStore(), CARD)
    routes = create_agent_card_routes(CARD) + create_jsonrpc_routes(handler, "/") + [Route("/health", health)]
    return Starlette(routes=routes)


if __name__ == "__main__":
    if not KEY:
        raise SystemExit("AGENT_TEST_LITELLM_KEY is empty: refusing to start")
    uvicorn.run(app(), host="0.0.0.0", port=8000)
