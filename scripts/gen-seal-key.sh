#!/usr/bin/env bash
# Generates openbao/seal.key: the 32 random bytes OpenBao's `static` seal
# uses to encrypt its root key, i.e. the thing that lets the vault unseal
# itself after every restart instead of waiting for an operator.
#
# Idempotent by default -- an existing key is left alone, because replacing
# it does not re-encrypt anything: OpenBao would come up unable to decrypt
# its own storage, and every secret in the vault would be lost. Rotating is
# a two-key dance through the seal stanza's previous_key/previous_key_id
# (see openbao/config.hcl), not a matter of regenerating this file.
#
# Usage: scripts/gen-seal-key.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_FILE="openbao/seal.key"
FORCE="${1:-}"

if [ -f "$KEY_FILE" ] && [ "$FORCE" != "--force" ]; then
  size=$(wc -c <"$KEY_FILE" | tr -d '[:space:]')
  if [ "$size" != "32" ]; then
    echo "gen-seal-key.sh: $KEY_FILE exists but is $size bytes, not 32." >&2
    echo "  OpenBao's static seal only takes a 32-byte (AES-256) key and will" >&2
    echo "  refuse to start. If the vault has never been initialised, delete it" >&2
    echo "  and re-run. If it has, that file is the only thing that can decrypt" >&2
    echo "  openbao-data -- restore the real one from your backup instead." >&2
    exit 1
  fi
  echo "gen-seal-key.sh: $KEY_FILE already exists, skipping (use --force to replace)"
  exit 0
fi

if [ -f "$KEY_FILE" ]; then
  echo "gen-seal-key.sh: replacing $KEY_FILE." >&2
  echo "  A vault already initialised under the old key CANNOT be read with" >&2
  echo "  this one. Ctrl-C now unless openbao-data is empty or expendable." >&2
fi

mkdir -p openbao
umask 077
openssl rand -out "$KEY_FILE" 32
chmod 600 "$KEY_FILE"

echo "gen-seal-key.sh: wrote $KEY_FILE (32 bytes, mode 600)."
echo
echo "  Back this up somewhere that is not this machine's disk -- it is what"
echo "  decrypts the openbao-data volume, and there is no recovering the vault"
echo "  without it. It is gitignored; it must never be committed."
