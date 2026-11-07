# Dev-session image: Claude Code plus what it needs to build Node, Python and
# Rust projects. No Docker in here, no sudo. Built on the daemon by
# `make dev-image` (tag devbox-session:<n>; bump the tag in
# scripts/portainer-images.sh and dev/session.compose.yml together, or
# `make dev-image FORCE=1` to rebuild the same tag).
#
# Base is node's Debian bookworm image: Debian's own nodejs (18) is past EOL.
# Debian's pip is PEP 668-managed: `pip install` wants a venv (python3 -m venv).
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

# Pinned: installed as root, so its auto-updater cannot update it anyway
# (DISABLE_AUTOUPDATER below). Bump here to upgrade.
ARG CLAUDE_CODE_VERSION=2.1.319

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server rclone jq less procps tmux \
      build-essential pkg-config libssl-dev python3 python3-pip python3-venv \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 # The base image's uid 1000 is "node"; rename it rather than add a second user.
 && usermod -l dev -d /home/dev -m node && groupmod -n dev node \
 # sshd checks this directory exists even when it runs unprivileged.
 && mkdir -p /run/sshd /work && chown dev:dev /work

COPY --chmod=755 entrypoint.sh sync.sh /usr/local/bin/
COPY --chown=dev:dev bashrc-devbox /home/dev/.bashrc-devbox

USER dev
# STATE is the dev-<session>-state volume: Claude's config and credentials,
# the SSH host key and the "restored" marker. It survives a recreated
# container; the bucket copy is what survives a delete.
ENV HOME=/home/dev \
    STATE=/home/dev/state \
    CLAUDE_CONFIG_DIR=/home/dev/state/claude \
    DISABLE_AUTOUPDATER=1 \
    NPM_CONFIG_PREFIX=/home/dev/.npm-global \
    PATH=/home/dev/.npm-global/bin:/home/dev/.cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component clippy,rustfmt \
 && mkdir -p ~/state/claude ~/.ssh ~/.npm-global && chmod 700 ~/.ssh ~/state \
 && ln -s state/claude ~/.claude \
 && echo '. ~/.bashrc-devbox' >> ~/.bashrc

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
