"""The Obsidian MCP server: three read-only tools over streamable HTTP, behind a bearer token.

LiteLLM is the only intended client (infra-net is shared with other containers, hence the
token). Configuration from the environment: S3_ENDPOINT, OBSIDIAN_BUCKET, OBSIDIAN_VAULT_PREFIX,
OBSIDIAN_MCP_S3_ACCESS_KEY, OBSIDIAN_MCP_S3_SECRET_KEY, OBSIDIAN_MCP_TOKEN.
"""
import hmac
import os

import boto3
import notes
from botocore.config import Config
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse


class RequireToken:
    """ASGI middleware: every HTTP request except /health needs `Authorization: Bearer <token>`."""

    def __init__(self, app, token: str):
        self.app, self._token = app, token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"] != "/health":
            auth = dict(scope["headers"]).get(b"authorization", b"")
            if not (auth.startswith(b"Bearer ") and hmac.compare_digest(auth[7:], self._token)):
                await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


def build_app(s3, bucket: str, vault_prefix: str, token: str):
    if not token:
        raise ValueError("OBSIDIAN_MCP_TOKEN must be set: infra-net is shared, the server must not be open")
    mcp = FastMCP("obsidian", host="0.0.0.0", port=8000, stateless_http=True, json_response=True)

    @mcp.custom_route("/health", methods=["GET"])
    async def health(_: Request):
        return PlainTextResponse("ok")

    @mcp.tool()
    def list_notes(prefix: str = "", limit: int = 200) -> list[str]:
        """List note paths (.md files) in the vault, optionally under a folder prefix such as "Projects/"."""
        return notes.list_notes(s3, bucket, prefix, min(max(limit, 1), 1000), vault_prefix)

    @mcp.tool()
    def read_note(path: str) -> str:
        """Read one note by its vault-relative path, e.g. "Inbox/idea.md" (text, up to 1 MiB)."""
        return notes.read_note(s3, bucket, path, vault_prefix)

    @mcp.tool()
    def search_notes(query: str, prefix: str = "", limit: int = 20) -> list[dict]:
        """Case-insensitive text search over the notes; returns each matching path with a short snippet."""
        return notes.search_notes(s3, bucket, query, prefix, min(max(limit, 1), 50), vault_prefix)

    return RequireToken(mcp.streamable_http_app(), token)


def main() -> None:
    import uvicorn

    s3 = boto3.client(
        "s3", endpoint_url=os.environ["S3_ENDPOINT"],
        aws_access_key_id=os.environ["OBSIDIAN_MCP_S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["OBSIDIAN_MCP_S3_SECRET_KEY"],
        region_name="us-east-1", config=Config(s3={"addressing_style": "path"}),
    )
    app = build_app(s3, os.environ.get("OBSIDIAN_BUCKET", "obsidian"),
                    os.environ.get("OBSIDIAN_VAULT_PREFIX", ""), os.environ.get("OBSIDIAN_MCP_TOKEN", ""))
    uvicorn.run(app, host="0.0.0.0", port=8000)


if __name__ == "__main__":
    main()
