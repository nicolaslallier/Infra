#!/usr/bin/env bash
# Samples GPU utilization on a Mac and writes it where node_exporter's
# textfile collector will pick it up, so the GPU panels on the "macOS
# machines" dashboard are fed by the same job="macos" scrape as every other
# panel there (same instance label, same Mac picker, no second port and no
# second Prometheus job).
#
# Why this script exists at all: node_exporter's darwin build has no GPU
# collector -- not disabled, absent -- so there is no node_* metric for GPU
# load on macOS and no flag that produces one. The numbers come from IOKit
# instead, via `ioreg`, which needs no root and no `powermetrics` (that one
# does need sudo, which a launchd agent should not have).
#
# Usage:
#   ./scripts/macos-gpu-textfile.sh [textfile-dir]
#   TEXTFILE_DIR=/opt/homebrew/var/node_exporter/textfile ./scripts/macos-gpu-textfile.sh
#
# Run it on a timer (scripts/install-macos-gpu-exporter.sh sets up the launchd
# agent that does), not once: each run is a point sample of the GPU's current
# utilization, so the sampling interval is the resolution of the chart.
set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-${1:-}}"
if [ -z "$TEXTFILE_DIR" ]; then
  prefix="$(brew --prefix 2>/dev/null || true)"
  TEXTFILE_DIR="${prefix:-/usr/local}/var/node_exporter/textfile"
fi

if ! command -v ioreg >/dev/null 2>&1; then
  echo "macos-gpu-textfile.sh: 'ioreg' not found -- this script only runs on macOS." >&2
  exit 1
fi

mkdir -p "$TEXTFILE_DIR"
out="$TEXTFILE_DIR/macos_gpu.prom"
# The textfile collector reads whatever is on disk the moment Prometheus
# scrapes, so a half-written file is a parse error on the whole scrape. Write
# a temp file in the same directory and rename it -- rename is atomic within a
# filesystem, a redirect into $out is not.
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# -r -d 1: print each IOAccelerator node (and its subclasses -- AGXAccelerator*
#          on Apple silicon, IntelAccelerator / AMDRadeon* on Intel) with its
#          own properties and none of its children.
# -w 0:    do not truncate lines; PerformanceStatistics is one long dict on a
#          single line and the utilization keys sit at the end of it.
ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | awk '
# Prometheus label values are quoted: a backslash or a quote in a registry
# name would produce an unparseable line rather than a wrong one.
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }

# Pulls the integer out of `"<key>"=<n>` inside the PerformanceStatistics dict.
# Matched case-insensitively (against a lowercased copy of the line) because
# the spelling is not stable across macOS releases and GPU families: the same
# counter shows up as "Device Utilization %" and as "device utilization".
function stat(line, key,   s) {
  s = tolower(line)
  if (match(s, "\"" key "\"[ ]*=[ ]*-?[0-9]+")) {
    s = substr(s, RSTART, RLENGTH)
    sub(/^.*=[ ]*/, "", s)
    return s
  }
  return ""
}

function add(family, sample) { body[family] = body[family] sample "\n" }

# One accelerator node is finished when the next one starts (or at EOF).
function flush(   label) {
  if (name == "") return
  # Two accelerators can carry the same registry name; two samples of one
  # metric with identical labels is a duplicate the textfile collector
  # rejects, taking the whole file with it.
  label = (name in seen) ? name "-" ++seen[name] : name
  seen[name] += 0
  found++

  add("macos_gpu_info", sprintf("macos_gpu_info{gpu=\"%s\",class=\"%s\",model=\"%s\"} 1", esc(label), esc(class), esc(model)))
  # IOKit reports utilization as a whole-number percentage; Prometheus
  # convention (and Grafana percentunit) wants the 0-1 ratio.
  if (dev   != "") add("macos_gpu_utilization_ratio",          sprintf("macos_gpu_utilization_ratio{gpu=\"%s\"} %.4f", esc(label), dev / 100))
  if (rend  != "") add("macos_gpu_renderer_utilization_ratio", sprintf("macos_gpu_renderer_utilization_ratio{gpu=\"%s\"} %.4f", esc(label), rend / 100))
  if (tiler != "") add("macos_gpu_tiler_utilization_ratio",    sprintf("macos_gpu_tiler_utilization_ratio{gpu=\"%s\"} %.4f", esc(label), tiler / 100))
  if (inuse != "") add("macos_gpu_memory_in_use_bytes",        sprintf("macos_gpu_memory_in_use_bytes{gpu=\"%s\"} %s", esc(label), inuse))
  if (alloc != "") add("macos_gpu_memory_allocated_bytes",     sprintf("macos_gpu_memory_allocated_bytes{gpu=\"%s\"} %s", esc(label), alloc))

  name = ""; class = ""; model = ""
  dev = ""; rend = ""; tiler = ""; inuse = ""; alloc = ""
}

/\+-o / {
  flush()
  name = $0
  sub(/^.*\+-o /, "", name)
  sub(/ +<class.*$/, "", name)
  sub(/[ \t]+$/, "", name)
  if (match($0, /<class [^,>]+/)) class = substr($0, RSTART + 7, RLENGTH - 7)
  next
}

# Apple silicon exposes a readable marketing name here ("Apple M1 Pro"); on
# Intel the same property is raw hex data, which is left undecoded rather than
# guessed at -- the registry name in `gpu` identifies the device either way.
name != "" && model == "" && /"model"/ {
  if (match($0, /<"[^"]*">/)) model = substr($0, RSTART + 2, RLENGTH - 4)
}

name != "" && /"PerformanceStatistics"/ {
  dev   = stat($0, "device utilization( %)?")
  rend  = stat($0, "renderer utilization( %)?")
  tiler = stat($0, "tiler utilization( %)?")
  inuse = stat($0, "in use system memory")
  alloc = stat($0, "alloc system memory")
}

END {
  flush()

  # Samples of one metric name have to be contiguous and carry exactly one
  # HELP/TYPE pair, so families are buffered above and printed in one go here.
  print "# HELP macos_gpu_accelerators Number of IOAccelerator devices found by ioreg."
  print "# TYPE macos_gpu_accelerators gauge"
  printf "macos_gpu_accelerators %d\n", found

  n = split("macos_gpu_info macos_gpu_utilization_ratio macos_gpu_renderer_utilization_ratio macos_gpu_tiler_utilization_ratio macos_gpu_memory_in_use_bytes macos_gpu_memory_allocated_bytes", order, " ")
  help["macos_gpu_info"]                          = "Registry name, IOKit class and model of each GPU."
  help["macos_gpu_utilization_ratio"]             = "Overall GPU busy fraction, 0-1 (IOKit Device Utilization)."
  help["macos_gpu_renderer_utilization_ratio"]    = "Render-engine busy fraction, 0-1 (IOKit Renderer Utilization)."
  help["macos_gpu_tiler_utilization_ratio"]       = "Tiler busy fraction, 0-1 (IOKit Tiler Utilization); Apple silicon only."
  help["macos_gpu_memory_in_use_bytes"]           = "System memory currently in use by the GPU."
  help["macos_gpu_memory_allocated_bytes"]        = "System memory allocated to the GPU."
  for (i = 1; i <= n; i++) {
    f = order[i]
    if (!(f in body)) continue
    printf "# HELP %s %s\n", f, help[f]
    printf "# TYPE %s gauge\n", f
    printf "%s", body[f]
  }
}
' > "$tmp"

chmod 644 "$tmp"
mv "$tmp" "$out"
trap - EXIT
