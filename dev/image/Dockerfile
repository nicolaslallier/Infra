# Claude Code session image (devbox-session:1). Node LTS on Debian bookworm,
# pinned tag@index digest like every image in this repo. Built by `make dev-image`.
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev git curl ca-certificates gnupg \
      python3 python3-venv python3-pip rclone openssh-server \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# The base image ships user "node" at uid 1000; replace it with "dev".
RUN userdel -r node \
 && useradd -m -u 1000 -s /bin/bash dev \
 && mkdir /work /home/dev/.state && chown dev:dev /work /home/dev/.state

COPY --chmod=0755 entrypoint.sh sync.sh /usr/local/bin/

USER dev
# The state volume (dev-<session>-state): Claude keeps .claude.json inside
# CLAUDE_CONFIG_DIR when it is set, and git its global config in GIT_CONFIG_GLOBAL.
ENV HOME=/home/dev PATH=/home/dev/.cargo/bin:$PATH \
    CLAUDE_CONFIG_DIR=/home/dev/.state/claude GIT_CONFIG_GLOBAL=/home/dev/.state/gitconfig
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal -c clippy
WORKDIR /work
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
