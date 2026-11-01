#!/usr/bin/env bash
# Log in to OpenBao through Keycloak (realm `infra`, OIDC), so people sign in
# with their Keycloak account -- which is where LDAP/AD users federate in --
# instead of the root token.
#
# Two halves, both idempotent:
#   1. Keycloak: group `openbao-admin` and confidential client `openbao`
#      (same shape as the s3-admin client in infra-realm.json; created here
#      too because `start --import-realm` skips a realm that already exists).
#   2. OpenBao: `oidc` auth method, `infra-admin` policy, and a role that only
#      lets members of `openbao-admin` in. The client secret is read from
#      Keycloak and written straight into OpenBao -- it never touches .env.
#
# Then add users to the `openbao-admin` group in Keycloak (realm infra ->
# Groups) and sign in at https://vault.infra.famillelallier.net/ui/vault/auth?with=oidc
#
# Usage: scripts/vault-oidc.sh
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "vault-oidc.sh: $*" >&2; exit 1; }
[ -f .env ] || die ".env not found (run 'make init' first)"
[ -f certs/infra-ca.crt ] || die "certs/infra-ca.crt missing (run 'make certs')"
# shellcheck source=/dev/null  # .env is generated, not lintable source
set -a; . ./.env; set +a
: "${KEYCLOAK_ADMIN:?}" "${KEYCLOAK_ADMIN_PASSWORD:?}"

VAULT_URL="https://vault.infra.famillelallier.net"
ISSUER="https://keycloak.famillelallier.net/realms/infra"
GROUP="openbao-admin"

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
bao() { ./scripts/vault-cli.sh "$@"; }

# --- 1. Keycloak ------------------------------------------------------------
kc config credentials --server http://localhost:8080 --realm master \
   --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

if ! kc get groups -r infra -q search="$GROUP" --fields name | grep -q "\"$GROUP\""; then
  kc create groups -r infra -s "name=$GROUP"
  echo "vault-oidc.sh: created Keycloak group $GROUP."
fi

if ! kc get clients -r infra -q clientId=openbao --fields clientId | grep -q openbao; then
  kc create clients -r infra -f - <<JSON
{
  "clientId": "openbao",
  "name": "OpenBao (OIDC login)",
  "protocol": "openid-connect",
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "implicitFlowEnabled": false,
  "serviceAccountsEnabled": false,
  "attributes": {"pkce.code.challenge.method": "S256"},
  "redirectUris": [
    "$VAULT_URL/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "webOrigins": [],
  "protocolMappers": [
    {"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
     "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                "access.token.claim": "true", "userinfo.token.claim": "true"}},
    {"name": "openbao-audience", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
     "config": {"included.client.audience": "openbao", "id.token.claim": "true", "access.token.claim": "true"}}
  ]
}
JSON
  echo "vault-oidc.sh: created Keycloak client openbao."
fi

cid="$(kc get clients -r infra -q clientId=openbao --fields id | jq -r '.[0].id')"
secret="$(kc get "clients/$cid/client-secret" -r infra | jq -r '.value')"
[ -n "$secret" ] && [ "$secret" != "null" ] || die "could not read the openbao client secret from Keycloak"

# --- 2. OpenBao -------------------------------------------------------------
bao auth list -format=json | jq -e 'has("oidc/")' >/dev/null || bao auth enable oidc
# Shows "OIDC" on the login page without a token (the UI lists methods unauthenticated).
bao auth tune -listing-visibility=unauth oidc

# Discovery goes through nginx (the keycloak.famillelallier.net alias on
# infra-net), whose certificate our local CA signed, hence the CA bundle.
# Secret via the environment, not --arg: argv is visible in the host's ps.
OIDC_SECRET="$secret" jq -n --arg url "$ISSUER" --arg id openbao \
      --rawfile ca certs/infra-ca.crt \
  '{oidc_discovery_url:$url, oidc_client_id:$id, oidc_client_secret:env.OIDC_SECRET,
    oidc_discovery_ca_pem:$ca, default_role:"admin"}' \
  | bao write auth/oidc/config -

printf 'path "*" {\n  capabilities = ["create","read","update","delete","list","sudo"]\n}\n' \
  | bao policy write infra-admin -

# bound_claims is what makes this "admin group only": a Keycloak user outside
# openbao-admin authenticates fine at Keycloak and is refused here.
jq -n --arg v "$VAULT_URL" --arg g "$GROUP" \
  '{role_type:"oidc", user_claim:"preferred_username", groups_claim:"groups",
    oidc_scopes:["openid","profile","email"], bound_audiences:["openbao"],
    bound_claims:{groups:[$g]}, token_policies:["infra-admin"], token_ttl:"8h",
    allowed_redirect_uris:["\($v)/ui/vault/auth/oidc/oidc/callback","http://localhost:8250/oidc/callback"]}' \
  | bao write auth/oidc/role/admin -

echo "vault-oidc.sh: done. Add users to Keycloak group $GROUP (realm infra), then sign in at"
echo "  $VAULT_URL/ui/vault/auth?with=oidc"
