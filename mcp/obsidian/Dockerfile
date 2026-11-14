# The read-only Obsidian MCP server (mcp/obsidian/server.py). Built on the daemon by
# `make app-images` from this repo's main (see scripts/portainer-images.sh): merge a change
# here, then bump the tag in docker-compose.mcp.yml and portainer-images.sh together.
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY notes.py server.py ./
USER 10001
EXPOSE 8000
CMD ["python", "server.py"]
