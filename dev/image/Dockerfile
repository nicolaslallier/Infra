# Dev-session image: Claude Code plus what it needs to build Node, Python and
# Rust projects. No Docker in here, no sudo. Built on the daemon by
# `make dev-image` (tag devbox-session:<n>; bump the tag in
# scripts/portainer-images.sh and dev/session.compose.yml together).
#
# Base is node's Debian bookworm image: Debian's own nodejs (18) is past EOL.
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server rclone jq less procps \
      build-essential pkg-config libssl-dev python3 python3-pip python3-venv \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force \
 # The base image's uid 1000 is "node"; rename it rather than add a second user.
 && usermod -l dev -d /home/dev -m node && groupmod -n dev node \
 # sshd checks this directory exists even when it runs unprivileged.
 && mkdir -p /run/sshd /work && chown dev:dev /work

COPY --chmod=755 entrypoint.sh sync.sh /usr/local/bin/

USER dev
ENV HOME=/home/dev \
    PATH=/home/dev/.cargo/bin:$PATH \
    CLAUDE_CONFIG_DIR=/home/dev/.claude
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component clippy,rustfmt \
 && mkdir -p ~/.claude ~/.ssh && chmod 700 ~/.ssh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
