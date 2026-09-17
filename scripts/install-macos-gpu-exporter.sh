#!/usr/bin/env bash
# Sets up GPU metrics on one Mac, for the GPU panels on the "macOS machines"
# Grafana dashboard. Run it ON THE MAC, not on the Docker host, once per
# machine -- it is idempotent, so re-running it after a `git pull` is fine.
#
# It installs two launchd agents in the user's own LaunchAgents directory (no
# sudo, no root):
#
#   net.famillelallier.macos-gpu-textfile   scripts/macos-gpu-textfile.sh,
#                                           every SAMPLE_INTERVAL seconds
#   net.famillelallier.node_exporter        node_exporter, with
#                                           --collector.textfile.directory
#
# The second one is the awkward part and is deliberate: node_exporter only
# reads a textfile directory when told to on the command line, and
# `brew services start node_exporter` runs the binary with no arguments and
# regenerates its plist on every restart, so an edited Homebrew plist does not
# survive. So this takes node_exporter over from `brew services` -- same
# binary, same :9100, same default collectors, one added flag -- and stops the
# brew service first so the two never fight over the port. `--uninstall`
# reverses both halves and hands node_exporter back to `brew services`.
#
#   ./scripts/install-macos-gpu-exporter.sh
#   ./scripts/install-macos-gpu-exporter.sh --uninstall
#
# Env overrides: TEXTFILE_DIR, SAMPLE_INTERVAL (seconds, default 15 to match
# Prometheus's scrape_interval), NODE_EXPORTER (path to the binary),
# LISTEN_ADDRESS (default :9100).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "install-macos-gpu-exporter.sh: this only runs on macOS (uname says $(uname -s))." >&2
  echo "Run it on each Mac you want GPU panels for, not on the Docker host." >&2
  exit 1
fi

AGENTS="$HOME/Library/LaunchAgents"
SAMPLER_LABEL="net.famillelallier.macos-gpu-textfile"
EXPORTER_LABEL="net.famillelallier.node_exporter"
SAMPLER_PLIST="$AGENTS/$SAMPLER_LABEL.plist"
EXPORTER_PLIST="$AGENTS/$EXPORTER_LABEL.plist"

PREFIX="$(brew --prefix 2>/dev/null || echo /usr/local)"
TEXTFILE_DIR="${TEXTFILE_DIR:-$PREFIX/var/node_exporter/textfile}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-15}"
LISTEN_ADDRESS="${LISTEN_ADDRESS:-:9100}"
LOG_DIR="$PREFIX/var/log"

# `launchctl bootout/bootstrap gui/<uid>` is the supported pair on macOS 11+;
# `load -w`/`unload -w` still works but prints deprecation noise. Booting out a
# label that is not loaded is an error, hence the `|| true` on every removal.
unload() { launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 || true; }
load()   { launchctl bootstrap "gui/$(id -u)" "$1"; }

if [ "${1:-}" = "--uninstall" ]; then
  unload "$SAMPLER_LABEL"
  unload "$EXPORTER_LABEL"
  rm -f "$SAMPLER_PLIST" "$EXPORTER_PLIST" "$TEXTFILE_DIR/macos_gpu.prom"
  echo "Removed both agents and the stale textfile."
  if command -v brew >/dev/null 2>&1; then
    echo "Hand node_exporter back to Homebrew with:  brew services start node_exporter"
  fi
  exit 0
fi

NODE_EXPORTER="${NODE_EXPORTER:-}"
if [ -z "$NODE_EXPORTER" ]; then
  NODE_EXPORTER="$(command -v node_exporter || true)"
fi
if [ -z "$NODE_EXPORTER" ] || [ ! -x "$NODE_EXPORTER" ]; then
  echo "install-macos-gpu-exporter.sh: node_exporter not found on PATH." >&2
  echo "Install it first ('brew install node_exporter'), or point NODE_EXPORTER at the binary." >&2
  exit 1
fi
# Resolve the Homebrew opt path when there is one: $PREFIX/bin/node_exporter is
# itself a symlink into the current Cellar version, and a plist pointing at a
# versioned Cellar path breaks on the next `brew upgrade`.
if [ -x "$PREFIX/opt/node_exporter/bin/node_exporter" ]; then
  NODE_EXPORTER="$PREFIX/opt/node_exporter/bin/node_exporter"
fi

mkdir -p "$AGENTS" "$TEXTFILE_DIR" "$LOG_DIR"

# Prove the sampler works on this machine before wiring it into launchd: a
# failure here is readable, the same failure inside a launchd agent is a silent
# empty panel.
echo "Sampling GPU metrics once..."
TEXTFILE_DIR="$TEXTFILE_DIR" "$REPO/scripts/macos-gpu-textfile.sh"
accelerators="$(awk '/^macos_gpu_accelerators /{print $2}' "$TEXTFILE_DIR/macos_gpu.prom")"
if [ "${accelerators:-0}" = "0" ]; then
  echo "  warning: ioreg reported no IOAccelerator devices on this Mac." >&2
  echo "  The agents will be installed anyway, but the GPU panels stay empty." >&2
else
  echo "  found $accelerators GPU(s):"
  sed -n 's/^macos_gpu_info{gpu="\([^"]*\)".*/    \1/p' "$TEXTFILE_DIR/macos_gpu.prom"
fi

# Homebrew's own node_exporter service binds :9100 with no textfile directory.
# Leaving it running means whichever agent wins the port decides whether GPU
# metrics exist -- and it is not deterministic which one that is.
if command -v brew >/dev/null 2>&1; then
  if brew services list 2>/dev/null | awk '$1 == "node_exporter" && $2 != "none" { found = 1 } END { exit !found }'; then
    echo "Stopping the Homebrew node_exporter service (this agent replaces it)..."
    brew services stop node_exporter >/dev/null 2>&1 || true
  fi
fi

cat > "$SAMPLER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SAMPLER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO/scripts/macos-gpu-textfile.sh</string>
    <string>$TEXTFILE_DIR</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$SAMPLE_INTERVAL</integer>
  <key>StandardErrorPath</key><string>$LOG_DIR/macos-gpu-textfile.err.log</string>
</dict>
</plist>
PLIST

cat > "$EXPORTER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$EXPORTER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_EXPORTER</string>
    <string>--collector.textfile.directory=$TEXTFILE_DIR</string>
    <string>--web.listen-address=$LISTEN_ADDRESS</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/node_exporter.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/node_exporter.err.log</string>
</dict>
</plist>
PLIST

unload "$SAMPLER_LABEL";  load "$SAMPLER_PLIST"
unload "$EXPORTER_LABEL"; load "$EXPORTER_PLIST"

echo
echo "Installed:"
echo "  $SAMPLER_PLIST  (every ${SAMPLE_INTERVAL}s -> $TEXTFILE_DIR/macos_gpu.prom)"
echo "  $EXPORTER_PLIST  ($NODE_EXPORTER on $LISTEN_ADDRESS)"
echo
case "$LISTEN_ADDRESS" in
  :*) probe="localhost$LISTEN_ADDRESS" ;;
  *)  probe="$LISTEN_ADDRESS" ;;
esac
echo "Confirm the metrics are being served:"
echo "  curl -s http://$probe/metrics | grep '^macos_gpu'"
echo
echo "Then make sure this Mac is listed in monitoring/prometheus/targets/macos.yml"
echo "and open Grafana -> Dashboards -> macOS machines -> GPU."
