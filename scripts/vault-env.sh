#!/usr/bin/env bash
# Regenerate .env from the vault (KV v2, infra/env).
#
# .env.example is used as the template rather than dumping bare KEY=value
# lines, so the regenerated file keeps every comment explaining what each
# setting is for, and keeps the keys in the order `make check-env` reports
# them. That also makes the result pass check-env by construction: the one
# thing it diffs is "every key .env.example assigns is present in .env".
#
# A key the vault does not have keeps whatever .env.example says (usually
# `change-me`) and is reported -- this never silently blanks a setting.
# Keys the vault has and .env.example does not are appended at the end,
# which is where a hand-added <APP>_DB_PASSWORD for an app in APP_DATABASES
# ends up.
#
# The previous .env is kept as .env.bak.
#
# Usage: scripts/vault-env.sh
set -euo pipefail
cd "$(dirname "$0")/.."

MOUNT="infra"
SECRET="env"

die() { echo "vault-env.sh: $*" >&2; exit 1; }

[ -f .env.example ] || die ".env.example not found -- it is the template this renders through."
[ -f .openbao.env ] || die ".openbao.env not found -- run 'make vault-init' first."

# shellcheck disable=SC1091
. ./.openbao.env
: "${BAO_TOKEN:?vault-env.sh: BAO_TOKEN not set in .openbao.env}"
export BAO_TOKEN

bao() { docker compose exec -T -e BAO_TOKEN openbao bao "$@"; }

secret_json="$(bao kv get -format=json -mount="$MOUNT" "$SECRET" 2>/dev/null | jq -c '.data.data' || true)"
if [ -z "$secret_json" ] || [ "$secret_json" = "null" ]; then
  die "$MOUNT/$SECRET is empty or unreadable.
  If this vault has never been seeded, run 'make vault-seed' first (it copies
  the current .env in). If it has, check that BAO_TOKEN in .openbao.env is
  still valid: 'docker compose exec openbao bao token lookup'."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$secret_json" > "$tmp/kv"

# Pass 1 reads the vault's KEY<TAB>VALUE pairs, pass 2 walks .env.example and
# substitutes. Values are emitted verbatim: whatever was seeded is what the
# container gets, with no quoting rules invented in between.
awk -F'\t' '
  NR == FNR {
    key = $1
    val = (index($0, "\t") ? substr($0, index($0, "\t") + 1) : "")
    have[key] = 1
    vals[key] = val
    next
  }
  {
    if (match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
      k = substr($0, RSTART, RLENGTH - 1)
      sub(/^[ \t]+/, "", k)
      if (k in have) {
        print k "=" vals[k]
        used[k] = 1
        next
      }
      notinvault[++nmiss] = k
      print $0
      next
    }
    print $0
  }
  END {
    n = 0
    for (k in have) if (!(k in used)) extra[++n] = k
    if (n > 0) {
      print ""
      print "# --- Settings held in the vault that .env.example does not define ---"
      print "# Appended by scripts/vault-env.sh. A per-app <APP>_DB_PASSWORD added"
      print "# by hand alongside an entry in APP_DATABASES lands here."
      # Insertion order is not preserved by awk arrays; sort for a stable file.
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (extra[j] < extra[i]) { t = extra[i]; extra[i] = extra[j]; extra[j] = t }
      for (i = 1; i <= n; i++) print extra[i] "=" vals[extra[i]]
    }
    for (i = 1; i <= nmiss; i++)
      print "vault-env.sh: " notinvault[i] " is not in the vault; kept .env.example'\''s value" > "/dev/stderr"
  }
' "$tmp/kv" .env.example > "$tmp/env"

[ -s "$tmp/env" ] || die "rendered an empty .env; refusing to install it."

if [ -f .env ]; then
  if cmp -s "$tmp/env" .env; then
    echo "vault-env.sh: .env already matches $MOUNT/$SECRET; left untouched."
    exit 0
  fi
  cp -p .env .env.bak
fi

umask 077
cp "$tmp/env" .env
chmod 600 .env

written="$(jq -r 'length' <<<"$secret_json")"
echo "vault-env.sh: wrote .env from $MOUNT/$SECRET ($written settings)"
[ -f .env.bak ] && echo "  previous .env kept as .env.bak"
echo "  'make check-env' verifies it; 'make up' deploys it."
