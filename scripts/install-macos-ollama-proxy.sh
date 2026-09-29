#!/usr/bin/env bash
# Puts ollama-metrics in front of the Ollama running on this Mac, so every
# request to <this Mac>:11434 is counted -- whichever machine sends it, and
# without touching any client. Run it ON THE MAC; idempotent.
#
#   before:  clients -> Ollama *:11434
#   after:   clients -> ollama-metrics *:11434 -> Ollama 127.0.0.1:11435
#
# Ollama.app reads OLLAMA_HOST from launchd's user environment, which
# `launchctl setenv` changes but does not keep across a reboot. So the one
# launchd agent this installs re-applies it at every login and, if Ollama
# already came up on :11434 first, restarts the app, then execs the proxy.
# Until Ollama has let go of the port the proxy's bind fails and KeepAlive
# retries it.
#
# Prometheus then scrapes <this Mac>:11434/metrics (job ollama, targets in
# monitoring/prometheus/prometheus.yml).
#
#   ./scripts/install-macos-ollama-proxy.sh
#   ./scripts/install-macos-ollama-proxy.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(uname -s)" = Darwin ] || { echo "Run this on the Mac that runs Ollama." >&2; exit 1; }

LABEL=net.famillelallier.ollama-metrics
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.local/bin/ollama-metrics"
LOG_DIR="$HOME/Library/Logs"
OLLAMA_ADDR=127.0.0.1:11435
# Same commit the stack's ollama-proxy image is built from.
REF=$(sed -n 's/^OLLAMA_PROXY_REF := //p' Makefile)

restart_ollama() {
  osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
  sleep 3
  open -a Ollama
}

if [ "${1:-}" = --uninstall ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  launchctl unsetenv OLLAMA_HOST
  restart_ollama
  echo "Removed; Ollama is back on :11434."
  exit 0
fi

command -v go >/dev/null || { echo "Needs Go: brew install go" >&2; exit 1; }
src=$(mktemp -d)
git clone -q https://github.com/nicolaslallier/ollama-metrics.git "$src"
git -C "$src" checkout -q "$REF"
mkdir -p "$(dirname "$BIN")" "$LOG_DIR"
(cd "$src" && go build -o "$BIN" .)
rm -rf "$src"

# lsof -c /^ollama$/ matches Ollama's server only, not ollama-metrics.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>launchctl setenv OLLAMA_HOST $OLLAMA_ADDR
if /usr/sbin/lsof -nP -a -c '/^ollama\$/' -iTCP:11434 -sTCP:LISTEN >/dev/null; then
  osascript -e 'quit app "Ollama"'; sleep 3; open -a Ollama; sleep 5
fi
exec "$BIN"</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>http://$OLLAMA_ADDR</string>
    <key>PORT</key><string>11434</string>
    <key>OLLAMA_SANITIZE_UTF8_RESPONSE</key><string>false</string>
    <key>OLLAMA_PROMOTE_REASONING_TO_CONTENT</key><string>false</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/ollama-metrics.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/ollama-metrics.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in $(seq 1 20); do
  curl -sf -m 2 http://localhost:11434/metrics | grep -q '^ollama_loaded_models' && break
  sleep 2
done
echo "Ollama:         $(curl -s -m 2 http://$OLLAMA_ADDR/api/version)"
echo "Proxy :11434:   $(curl -s -m 2 http://localhost:11434/api/version)"
curl -s -m 2 http://localhost:11434/metrics | grep '^ollama_loaded_models' \
  || { echo "Proxy not serving metrics yet; see $LOG_DIR/ollama-metrics.log" >&2; exit 1; }
