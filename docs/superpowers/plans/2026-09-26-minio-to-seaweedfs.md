# Replace MinIO with SeaweedFS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `minio` service with a SeaweedFS S3 server (`s3`), with bucket-scoped per-app identities, a Keycloak-gated admin UI, and STS for humans. Consumers talk to it exactly as they did to MinIO.

**Architecture:**
- **`s3`** is one `weed server -s3` container. It is authenticated from first boot by an env-provided admin identity, and it loads an advanced IAM config (Keycloak OIDC provider + STS roles) rendered from a committed template.
- **`s3-admin`** is a `weed admin` container behind a third oauth2-proxy (`oauth2-proxy-infra`) against a new Keycloak realm `infra`.
- **Provisioning** is one generic `make s3-provision`.
- **NGINX** fronts both under `*.infra.famillelallier.net`. Prometheus scrapes one `seaweedfs` job.

**Tech Stack:** Docker Compose (Portainer Git stack), SeaweedFS 4.47 (`chrislusf/seaweedfs`), Keycloak 26.7 realm import, oauth2-proxy v7.6.0, NGINX (`nginx:alpine-otel`), Prometheus/Grafana provisioning JSON, bash (macOS bash 3.2 compatible).

**Spec:** `docs/superpowers/specs/2026-09-26-minio-to-seaweedfs-design.md` (revised 2026-09-26: admin UI via oauth2-proxy; 4.47 facts). Read it before starting any task.

## Global Constraints

- Image: `chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882` for both `s3` and `s3-admin`, pinned by tag **and** digest.
- **Names:** service `s3`, endpoint `http://s3:8333`, public names `s3.infra.famillelallier.net` and `s3-admin.infra.famillelallier.net`, env keys `S3_*`. No `minio` alias anywhere.
- **No ports:** neither `s3`, `s3-admin` nor `oauth2-proxy-infra` gets a `ports:` key (single-ingress rule).
- **`:?` guards:** every repo bind mount uses `${INFRA_DIR:-.}`. The oauth2-proxy **client** secret (`S3_ADMIN_OAUTH_CLIENT_SECRET`) gets **no** `:?` guard; its cookie secret does.
- **Cookie-secret recipes** end in `| tr -- '+/' '-_'`.
- **STS key:** `S3_STS_SIGNING_KEY` is standard base64 and decodes to ≥ 16 bytes (recipe `openssl rand -base64 32`).
- **Realm file:** no client `secret` and no `users` array in `keycloak/realm-import/infra-realm.json`. Redirect URIs are exact, with no trailing `*`.
- **Bucket names are unchanged:** `jarvis`, `obsidian`, `ea-catalogue`, `darkangel-files`. Each app identity = access key = app name, scoped to its one bucket, never `Admin`.
- **Scripts:** must pass `shellcheck -S warning` and run on macOS `/bin/bash` 3.2 (no `mapfile`, no `${var,,}`).
- **Docs:** historical `docs/superpowers/*` files are not edited (other than this plan and the spec).
- **Acceptance:** `git grep -i minio -- ':!docs/superpowers'` returns nothing.

## Review Focus

1. **A bad `S3_STS_SIGNING_KEY`** (url-safe alphabet, unpadded, too short) must block deploy in `check-env`. SeaweedFS only logs `Failed to load IAM configuration` and then serves S3 with STS silently off. Pinned in Task 1 (bad-key cases) and Task 2 (STS probe answers `AccessDenied`, not `ServiceUnavailable`).
2. **Re-running `make s3-provision`** for a versioned bucket must leave versioning `Enabled`. `s3.bucket.create` on an existing bucket silently resets it. Pinned in Task 3 (re-run, then check versioning).
3. **Hostile or malformed `app=` / `bucket=` / secret values** (uppercase, spaces, `;`, a secret with a space) must be refused before anything reaches `weed shell`. Otherwise a value can inject a second shell command. Pinned in Task 3 (rejection cases).
4. **Test containers from a worktree** join the live `infra-net`. A leftover worktree `s3` after cutover would answer as `s3` next to the real one. Running the harness from the main checkout would touch the live stack. Pinned by `wt_guard` + `no_other_s3` in the Test Harness and the teardown step closing Tasks 2, 3, 4 and 6.
5. **An `infra` realm user outside `s3-admin`** (including `s3-readonly`) must get a 403 from the admin gate, not a UI session. `-allowInsecureBind` means oauth2-proxy is the only auth. Pinned in Task 8 (acceptance A6).

---

## Test Harness (used by Tasks 2–4, 6)

This repo has no unit-test framework. Validation means running the real containers. Before merge, run only `s3`/`s3-admin` from the **implementation worktree** as that worktree's own compose project, on the real `infra-net`, with a throwaway `.env`. Paste these helpers into your shell at the worktree root:

```bash
# Refuse to run anything from the main checkout (its compose project is the live `infra`).
wt_guard() {
  [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] \
    || { echo "STOP: main checkout, not a linked worktree" >&2; return 1; }
}
# There must be no other `s3` on infra-net (true before cutover; false after it).
no_other_s3() {
  if docker run --rm --network infra-net busybox nslookup s3 >/dev/null 2>&1; then
    echo "STOP: something already answers as s3 on infra-net" >&2; return 1
  fi
}
# aws_as <access_key> <secret_key> <aws-cli args...>  -- talks to http://s3:8333
aws_as() {
  local ak=$1 sk=$2; shift 2
  docker run --rm -i --network infra-net \
    -e AWS_ACCESS_KEY_ID="$ak" -e AWS_SECRET_ACCESS_KEY="$sk" -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli --endpoint-url http://s3:8333 "$@"
}
# curl from inside infra-net
icurl() { docker run --rm --network infra-net curlimages/curl -sS "$@"; }
env_get() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }
```

Bring-up (from Task 2 on):

```bash
wt_guard && { [ -f .env ] || ./scripts/ci-fake-env.sh; }   # throwaway .env + certs; refuses to overwrite a real .env
wt_guard && no_other_s3 && docker compose up -d s3
```

Teardown (end of every task that brought it up). This removes **only this worktree's** containers and volumes:

```bash
wt_guard && docker compose down -v
docker ps -a --filter "label=com.docker.compose.project=$(basename "$PWD" | tr '[:upper:]' '[:lower:]')" --format '{{.Names}}'   # expect: no output
```

Static checks (the same ones the nightly `infra-pr-validation` DAG runs):

```bash
docker run --rm -v "$PWD:/repo:ro" -w /repo koalaman/shellcheck-alpine:stable sh -c 'shellcheck -S warning scripts/*.sh postgres/initdb/*.sh'
docker compose --env-file .env -f docker-compose.yml config -q
docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/nginx/stream.d:/etc/nginx/stream.d:ro" -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/certs:/etc/nginx/certs:ro" nginx:alpine-otel nginx -t
```

---

### Task 1: Env keys and preflight

**Files:**
- Modify: `.env.example:48-65` (the `# --- MinIO ---` section)
- Modify: `scripts/check-env.sh:3-4,51-70,76-79,84-87`, plus a new check after line 243
- Modify: `scripts/ci-fake-env.sh:40-65`

**Interfaces:**
- Produces: env keys `S3_ADMIN_ACCESS_KEY`, `S3_ADMIN_SECRET_KEY`, `S3_STS_SIGNING_KEY`, `S3_ADMIN_OAUTH_CLIENT_SECRET`, `S3_ADMIN_OAUTH_COOKIE_SECRET`, `JARVIS_S3_SECRET_KEY`, `OBSIDIAN_S3_SECRET_KEY`, `EA_S3_SECRET_KEY`, `DARKANGEL_S3_SECRET_KEY`. Tasks 2–4 read exactly these names.
- Removes: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `OBSIDIAN_MINIO_SECRET_KEY`, `EA_MINIO_SECRET_KEY`.

- [ ] **Step 1: Write the failing check.** At the worktree root, generate a throwaway `.env` and prove today's `check-env` does not know the new keys:

```bash
wt_guard && ./scripts/ci-fake-env.sh
grep -c '^S3_STS_SIGNING_KEY=' .env
```
Expected: `0` (the key does not exist yet).

- [ ] **Step 2: Replace the MinIO section of `.env.example`.** Replace lines 48–65 (`# --- MinIO ---` through `EA_MINIO_SECRET_KEY=change-me`) with:

```
# --- S3 (SeaweedFS) ---
# Admin identity of the object store, created from these on every boot.
# Nothing but `make s3-provision` and break-glass use it; apps get their own
# bucket-scoped keys below.
S3_ADMIN_ACCESS_KEY=s3admin
S3_ADMIN_SECRET_KEY=change-me

# Signs STS session tokens (temporary S3 credentials for humans, see README).
# Standard base64 of >= 16 bytes -- SeaweedFS only logs a bad key and runs
# with STS off, so check-env rejects one up front.
#   openssl rand -base64 32
S3_STS_SIGNING_KEY=change-me

# Per-app S3 secret keys; the access key is the app name. Applied by
# `make s3-provision app=<name>`, not at boot -- re-run it after changing one
# (it replaces the old secret in place), and copy the value into the app.
JARVIS_S3_SECRET_KEY=change-me
OBSIDIAN_S3_SECRET_KEY=change-me
EA_S3_SECRET_KEY=change-me
DARKANGEL_S3_SECRET_KEY=change-me

# oauth2-proxy-infra gates https://s3-admin.infra.famillelallier.net
# (Keycloak realm `infra`, group `s3-admin`).
# 1. First `make up` imports the realm; then copy realm infra -> Clients ->
#    s3-admin -> Credentials into S3_ADMIN_OAUTH_CLIENT_SECRET below, then
#    `make vault-seed` and `make up` again.
S3_ADMIN_OAUTH_CLIENT_SECRET=change-me
# 2. Session cookie key, needed before the first boot:
#   openssl rand -base64 32 | tr -- '+/' '-_'
S3_ADMIN_OAUTH_COOKIE_SECRET=change-me
```

- [ ] **Step 3: Update the lists in `scripts/check-env.sh`.**
  - **Header, lines 3–4:** replace `` `keycloak-seed-users` and `obsidian-minio`. `` with `` `keycloak-seed-users` and `s3-provision`. ``
  - **`REQUIRED` (lines 51–70):** delete `MINIO_ROOT_PASSWORD`, `OBSIDIAN_MINIO_SECRET_KEY` and `EA_MINIO_SECRET_KEY`. Add, in their place:

```bash
	S3_ADMIN_ACCESS_KEY
	S3_ADMIN_SECRET_KEY
	S3_STS_SIGNING_KEY
	JARVIS_S3_SECRET_KEY
	OBSIDIAN_S3_SECRET_KEY
	EA_S3_SECRET_KEY
	DARKANGEL_S3_SECRET_KEY
```
  - **End of `REQUIRED`**, after `EA_OBSIDIAN_OAUTH_COOKIE_SECRET`: add `	S3_ADMIN_OAUTH_COOKIE_SECRET`.
  - **`COOKIE_SECRETS` (lines 76–79):** add `	S3_ADMIN_OAUTH_COOKIE_SECRET`.
  - **`POST_BOOT` (lines 84–87):** add `	S3_ADMIN_OAUTH_CLIENT_SECRET:oauth2-proxy-infra:infra:s3-admin`.

- [ ] **Step 4: Add the STS key check.** Insert directly after the `COOKIE_SECRETS` loop's closing `done` (line 243), before `if [ -z "${LAN_IP:-}" ]`:

```bash
# SeaweedFS decodes the STS signing key as *standard* base64 (a Go []byte in
# its IAM JSON) and needs at least 16 bytes. A bad key is not fatal to it: it
# logs "Failed to load IAM configuration" and serves S3 with STS switched
# off, which nobody notices until a human's credential request fails.
sts="${S3_STS_SIGNING_KEY:-}"
if [ -n "$sts" ] && [ "$sts" != "$PLACEHOLDER" ]; then
	sts_len=""
	case "$sts" in
	*[!A-Za-z0-9+/=]*) ;;
	*) [ $(( ${#sts} % 4 )) -eq 0 ] && sts_len=$(b64url_len "$(printf '%s' "$sts" | tr -- '+/' '-_')") ;;
	esac
	if [ -z "$sts_len" ] || [ "$sts_len" -lt 16 ]; then
		errors+=("S3_STS_SIGNING_KEY is not padded standard base64 of at least 16 bytes -- SeaweedFS would start with STS silently off; generate one with \"openssl rand -base64 32\"")
	fi
fi
```

- [ ] **Step 5: Teach `scripts/ci-fake-env.sh` the shaped values.** After `cookie_b="$(b64_32 | tr -d '=')"` add `cookie_c="$(b64_32 | tr -d '=')"`. After the `set_key EA_OBSIDIAN_OAUTH_COOKIE_SECRET` line add:

```bash
set_key S3_ADMIN_OAUTH_COOKIE_SECRET "$cookie_c"
# Standard base64, padding kept: SeaweedFS's STS key is a Go []byte in JSON.
set_key S3_STS_SIGNING_KEY "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
```
In the header's bullet list, change "the two oauth2-proxy cookie keys" to "the three oauth2-proxy cookie keys", and add the bullet `#   - S3_STS_SIGNING_KEY is padded standard base64 of 32 bytes`.

- [ ] **Step 6: Run the checks and verify they pass.**

```bash
wt_guard && rm -f .env && ./scripts/ci-fake-env.sh && SKIP_DOCKER_CHECK=1 ./scripts/check-env.sh; echo "exit=$?"
```
Expected: `exit=0`, with no `check-env:` error lines. `ci-fake-env` fills every `change-me`, the client secrets included, so there is no POST_BOOT warning either.

Then prove the new POST_BOOT entry is wired: `sed -i '' 's|^S3_ADMIN_OAUTH_CLIENT_SECRET=.*|S3_ADMIN_OAUTH_CLIENT_SECRET=|' .env && SKIP_DOCKER_CHECK=1 ./scripts/check-env.sh 2>&1 | grep -c 'oauth2-proxy-infra will crash-loop'`. Expected: `1`, with exit still 0.

- [ ] **Step 7: Verify the bad-key cases fail** (Review Focus 1):

```bash
for bad in 'c2hvcnQ=' 'abc-def_ghi-jkl_mno-pqr_stu-vwx_yz01234' 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo'; do
  sed -i '' "s|^S3_STS_SIGNING_KEY=.*|S3_STS_SIGNING_KEY=$bad|" .env
  SKIP_DOCKER_CHECK=1 ./scripts/check-env.sh 2>&1 | grep -c 'S3_STS_SIGNING_KEY is not padded' ; done
```
Expected: `1` three times. The cases are too short, url-safe alphabet, and unpadded. Then restore a good key with `sed -i '' "s|^S3_STS_SIGNING_KEY=.*|S3_STS_SIGNING_KEY=$(openssl rand -base64 32)|" .env` and re-run Step 6. It must print `exit=0` again.

- [ ] **Step 8: shellcheck.** Run the shellcheck line from the Test Harness. Expected: no output, exit 0.

- [ ] **Step 9: Commit**

```bash
git add .env.example scripts/check-env.sh scripts/ci-fake-env.sh
git commit -m "feat(s3): add SeaweedFS env keys and STS key preflight"
```

---

### Task 2: The `s3` service and its IAM config

**Files:**
- Create: `seaweedfs/iam.json.tmpl`
- Modify: `docker-compose.yml:511-538` (replace the `minio` service), `:741` (volume), `:175-176` (stale comment)

**Interfaces:**
- Consumes: `S3_ADMIN_ACCESS_KEY`, `S3_ADMIN_SECRET_KEY`, `S3_STS_SIGNING_KEY` (Task 1).
- Produces: service `s3` on `infra-net`. S3 on `s3:8333` (STS on the same port), master on `s3:9333`, Prometheus metrics on `s3:9324/metrics`, volume `s3-data`. Role ARNs `arn:aws:iam::role/S3AdminRole`, `…/S3WriteRole`, `…/S3ReadOnlyRole`. Keycloak groups consumed: `s3-admin`, `s3-readwrite`, `s3-readonly` in claim `groups`.

- [ ] **Step 1: Write the failing probe.**

```bash
wt_guard && no_other_s3 && docker compose up -d s3; echo "exit=$?"
```
Expected: a non-zero exit with `no such service: s3`.

- [ ] **Step 2: Create `seaweedfs/iam.json.tmpl`.**

```json
{
  "sts": {
    "tokenDuration": "1h",
    "maxSessionLength": "12h",
    "issuer": "seaweedfs-sts",
    "signingKey": "__S3_STS_SIGNING_KEY__"
  },
  "providers": [
    {
      "name": "keycloak",
      "type": "oidc",
      "enabled": true,
      "config": {
        "issuer": "https://keycloak.famillelallier.net/realms/infra",
        "clientId": "s3-sts",
        "jwksUri": "http://keycloak:8080/realms/infra/protocol/openid-connect/certs",
        "roleMapping": {
          "rules": [
            { "claim": "groups", "value": "s3-admin", "role": "arn:aws:iam::role/S3AdminRole" },
            { "claim": "groups", "value": "s3-readwrite", "role": "arn:aws:iam::role/S3WriteRole" },
            { "claim": "groups", "value": "s3-readonly", "role": "arn:aws:iam::role/S3ReadOnlyRole" }
          ]
        }
      }
    }
  ],
  "policies": [
    {
      "name": "S3AdminPolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Action": ["s3:*"], "Resource": ["arn:aws:s3:::*", "arn:aws:s3:::*/*"] }
        ]
      }
    },
    {
      "name": "S3WritePolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Action": ["s3:Get*", "s3:List*", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
            "Resource": ["arn:aws:s3:::*", "arn:aws:s3:::*/*"]
          }
        ]
      }
    },
    {
      "name": "S3ReadOnlyPolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Action": ["s3:Get*", "s3:List*"], "Resource": ["arn:aws:s3:::*", "arn:aws:s3:::*/*"] }
        ]
      }
    }
  ],
  "roles": [
    {
      "roleName": "S3AdminRole",
      "roleArn": "arn:aws:iam::role/S3AdminRole",
      "attachedPolicies": ["S3AdminPolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": { "Federated": "*" },
            "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": {
              "StringEquals": {
                "oidc:iss": "https://keycloak.famillelallier.net/realms/infra",
                "oidc:groups": ["s3-admin"]
              }
            }
          }
        ]
      }
    },
    {
      "roleName": "S3WriteRole",
      "roleArn": "arn:aws:iam::role/S3WriteRole",
      "attachedPolicies": ["S3WritePolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": { "Federated": "*" },
            "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": {
              "StringEquals": {
                "oidc:iss": "https://keycloak.famillelallier.net/realms/infra",
                "oidc:groups": ["s3-readwrite", "s3-admin"]
              }
            }
          }
        ]
      }
    },
    {
      "roleName": "S3ReadOnlyRole",
      "roleArn": "arn:aws:iam::role/S3ReadOnlyRole",
      "attachedPolicies": ["S3ReadOnlyPolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": { "Federated": "*" },
            "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": {
              "StringEquals": {
                "oidc:iss": "https://keycloak.famillelallier.net/realms/infra",
                "oidc:groups": ["s3-readonly", "s3-readwrite", "s3-admin"]
              }
            }
          }
        ]
      }
    }
  ]
}
```
`roleMapping` only picks the default role a bare `AssumeRoleWithWebIdentity`
resolves to — it does not gate which role a request naming a `RoleArn` may
assume; that gate is each role's trust policy above, which ANDs `oidc:iss`
with a matching `oidc:groups` value. A realm user in no group, or asking
for a role above their group, gets no credentials for it.

- [ ] **Step 3: Replace the `minio` service in `docker-compose.yml`.** Delete lines 511–538 (from `# --- Object storage (API + console via NGINX; no host ports) ---` through the minio healthcheck's `start_period: 20s`) and put this in their place:

```yaml
  # --- Object storage: SeaweedFS (S3 via NGINX; no host ports) ---

  s3:
    # Tag *and* digest, like neo4j: a storage-format change must not ride
    # along with a redeploy.
    image: chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882
    restart: unless-stopped
    # Renders the IAM template into the container's /tmp (the STS signing key
    # never touches the host), then hands over to the image's own
    # entrypoint, which drops root to the `seaweed` user -- replacing the
    # entrypoint outright would run weed as root. `$$` keeps Compose from
    # interpolating the key into this command line; the shell reads it from
    # the environment.
    #   -ip=s3 -ip.bind=0.0.0.0  weed binds the detected container IP by
    #     default, which breaks the loopback healthcheck and `weed shell
    #     -master=...`; `s3` is the address s3-admin reaches the master on.
    #   -s3.port.iceberg/lance=0  catalog listeners we don't use.
    entrypoint:
      - /bin/sh
      - -c
      - >-
        sed "s|__S3_STS_SIGNING_KEY__|$$S3_STS_SIGNING_KEY|"
        /etc/seaweedfs/iam.json.tmpl > /tmp/iam.json &&
        exec /entrypoint.sh server -ip=s3 -ip.bind=0.0.0.0 -s3
        -s3.iam.config=/tmp/iam.json -s3.port.iceberg=0 -s3.port.lance=0
        -metricsPort=9324
    environment:
      # The admin identity. It must exist from the very first boot: with no
      # identity at all, SeaweedFS S3 serves every request anonymously.
      AWS_ACCESS_KEY_ID: ${S3_ADMIN_ACCESS_KEY:?Set S3_ADMIN_ACCESS_KEY in .env}
      AWS_SECRET_ACCESS_KEY: ${S3_ADMIN_SECRET_KEY:?Set S3_ADMIN_SECRET_KEY in .env}
      S3_STS_SIGNING_KEY: ${S3_STS_SIGNING_KEY:?Set S3_STS_SIGNING_KEY in .env (openssl rand -base64 32)}
    volumes:
      - s3-data:/data
      - ${INFRA_DIR:-.}/seaweedfs/iam.json.tmpl:/etc/seaweedfs/iam.json.tmpl:ro
    networks:
      - infra-net
    healthcheck:
      # /healthz answers 200 without S3 auth.
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8333/healthz"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
```
In the top-level `volumes:` list, replace `  minio-data:` (line 741) with `  s3-data:`.

In the `oauth2-proxy` comment (lines 175–176), replace `(same reasoning as the MINIO_SERVER_URL note / on the minio service above)` with `(no need to hairpin through NGINX's TLS from inside infra-net)`, keeping the comment's line wrapping.

- [ ] **Step 4: Validate the compose file.** `docker compose --env-file .env -f docker-compose.yml config -q`. Expected: no output, exit 0.

- [ ] **Step 5: Bring `s3` up and run the probes.**

```bash
wt_guard && no_other_s3 && docker compose up -d s3
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q s3)")" = healthy ]; do sleep 3; done
icurl -o /dev/null -w '%{http_code}\n' http://s3:8333/                                  # unsigned ListBuckets
aws_as "$(env_get S3_ADMIN_ACCESS_KEY)" "$(env_get S3_ADMIN_SECRET_KEY)" s3api list-buckets   # admin identity
icurl -X POST http://s3:8333/ --data 'Action=AssumeRoleWithWebIdentity&Version=2011-06-15&RoleArn=arn:aws:iam::role/S3ReadOnlyRole&RoleSessionName=t&WebIdentityToken=bogus'
docker compose logs s3 | grep -c 'Failed to load IAM configuration'
docker compose exec -T s3 ps -o user,args | grep 'weed server'
```
Expected, in order:
- `403`: auth is on from first boot.
- A JSON `{"Buckets": [] …}`.
- An XML `ErrorResponse` whose `<Code>` is `AccessDenied` (or `InvalidParameterValue`), **not** `ServiceUnavailable`, which would mean STS is not loaded.
- `0`.
- A `seaweed` user, not `root`.

- [ ] **Step 6: Tear down** (Test Harness teardown). Expected: the `docker ps` filter prints nothing.

- [ ] **Step 7: Commit**

```bash
git add seaweedfs/iam.json.tmpl docker-compose.yml
git commit -m "feat(s3): replace minio with SeaweedFS s3 service and STS IAM config"
```

---

### Task 3: Generic S3 provisioning

**Files:**
- Create: `scripts/provision-s3.sh`
- Modify: `Makefile:10-16` (`.PHONY`), `:268-272` (targets)
- Delete: `scripts/provision-obsidian-minio.sh`, `scripts/provision-ea-minio.sh`

**Interfaces:**
- Consumes: service `s3` (Task 2), `<APP>_S3_SECRET_KEY` (Task 1).
- Produces: `make s3-provision app=<name> [bucket=<bucket>] [versioned=1]` → `scripts/provision-s3.sh <app> <bucket> <0|1>`. It creates identity `<app>` with access key `<app>`, scoped `Read,Write,List,Tagging` on `<bucket>`.

- [ ] **Step 1: Write the failing probe.** `make s3-provision app=jarvis; echo "exit=$?"`. Expected: `No rule to make target 's3-provision'`, non-zero.

- [ ] **Step 2: Create `scripts/provision-s3.sh`** (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Create/update an app's bucket and its bucket-scoped S3 identity on the
# SeaweedFS `s3` service -- the object-store twin of provision-app.sh.
# Idempotent: re-run it to rotate <APP>_S3_SECRET_KEY. The access key stays
# the app name, so the new secret replaces the old one in place.
#
# Usage: scripts/provision-s3.sh <app> [bucket] [versioned]
#   bucket    defaults to <app>
#   versioned 1 enables bucket versioning (default 0)
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/provision-s3.sh <app> [bucket] [versioned]}"
bucket="${2:-$app}"
versioned="${3:-0}"

# Every value below ends up inside a `weed shell` command line, which splits
# on whitespace and runs `;`-separated commands -- so validate, don't quote.
name_re='^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
[[ "$app" =~ $name_re ]] || { echo "provision-s3.sh: app '$app' must be 3-63 chars of a-z, 0-9, '-'" >&2; exit 1; }
[[ "$bucket" =~ $name_re ]] || { echo "provision-s3.sh: bucket '$bucket' must be 3-63 chars of a-z, 0-9, '-'" >&2; exit 1; }
case "$versioned" in 0 | 1) ;; *) echo "provision-s3.sh: versioned must be 0 or 1" >&2; exit 1 ;; esac

if [ ! -f .env ]; then
  echo "provision-s3.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

var_name="$(printf '%s' "${app}_S3_SECRET_KEY" | tr 'a-z-' 'A-Z_')"
secret="$(grep -E "^${var_name}=" .env | tail -n1 | cut -d= -f2-)"
if [ -z "$secret" ] || [ "$secret" = change-me ]; then
  echo "provision-s3.sh: ${var_name} not set in .env" >&2
  echo "  Add a line like: ${var_name}=\$(openssl rand -hex 24)" >&2
  exit 1
fi
[[ "$secret" =~ ^[A-Za-z0-9+/=_-]{16,}$ ]] || {
  echo "provision-s3.sh: ${var_name} must be >= 16 chars of A-Z a-z 0-9 + / = _ -" >&2
  exit 1
}

# `-e NAME` with no value: docker takes it from this process's environment,
# so the secret never appears in an argv (ps).
export S3P_APP="$app" S3P_BUCKET="$bucket" S3P_SECRET="$secret" S3P_VERSIONED="$versioned"
docker compose exec -T -e S3P_APP -e S3P_BUCKET -e S3P_SECRET -e S3P_VERSIONED \
  s3 sh -eu -s <<'EOF'
ws() { printf '%s\n' "$1" | weed shell -master=s3:9333; }

# s3.bucket.create on an existing bucket silently replaces its entry --
# versioning flag included -- so only create what is not there yet.
if ! ws "s3.bucket.list" | awk '{print $1}' | grep -qxF "$S3P_BUCKET"; then
  ws "s3.bucket.create -name $S3P_BUCKET"
fi

ws "s3.configure -user $S3P_APP -access_key $S3P_APP -secret_key $S3P_SECRET -buckets $S3P_BUCKET -actions Read,Write,List,Tagging -apply" >/dev/null

if [ "$S3P_VERSIONED" = 1 ]; then
  ws "s3.bucket.versioning -name $S3P_BUCKET -enable"
fi
echo "bucket '$S3P_BUCKET' + identity '$S3P_APP' ready"
EOF
```
The `s3.configure` output goes to `/dev/null` because it echoes the identity, secret included.

- [ ] **Step 3: Replace the Makefile targets.**
  - In `.PHONY` (line 13), replace `keycloak-seed-users obsidian-minio ea-minio` with `keycloak-seed-users s3-provision`.
  - Replace lines 268–272 (the `obsidian-minio` and `ea-minio` targets) with the block below. Recipe lines start with a **tab**.

```make
s3-provision: check-env ## Create/update an app's S3 bucket + identity (app=<name> [bucket=] [versioned=1])
	@test -n "$(app)" || { echo "usage: make s3-provision app=<name> [bucket=<bucket>] [versioned=1]" >&2; exit 1; }
	@./scripts/provision-s3.sh "$(app)" "$(or $(bucket),$(app))" "$(or $(versioned),0)"
```

- [ ] **Step 4: Delete the old scripts.** `git rm scripts/provision-obsidian-minio.sh scripts/provision-ea-minio.sh`

- [ ] **Step 5: Bring `s3` up, provision two apps, and run the isolation probes.**

```bash
wt_guard && no_other_s3 && docker compose up -d s3
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q s3)")" = healthy ]; do sleep 3; done
make s3-provision app=obsidian versioned=1
make s3-provision app=ea bucket=ea-catalogue
aws_as obsidian "$(env_get OBSIDIAN_S3_SECRET_KEY)" s3 cp - s3://obsidian/o.txt <<<'hi'
aws_as obsidian "$(env_get OBSIDIAN_S3_SECRET_KEY)" s3 ls s3://obsidian/
aws_as obsidian "$(env_get OBSIDIAN_S3_SECRET_KEY)" s3 ls s3://ea-catalogue/ ; echo "cross=$?"
aws_as ea "$(env_get EA_S3_SECRET_KEY)" s3 cp - s3://obsidian/x.txt <<<'x' ; echo "cross=$?"
aws_as "$(env_get S3_ADMIN_ACCESS_KEY)" "$(env_get S3_ADMIN_SECRET_KEY)" s3api get-bucket-versioning --bucket obsidian
```
If the first `make` fails with `S3P_APP: parameter not set`, this Compose version does not forward a bare `-e NAME`. In that case switch the `exec` line to `-e S3P_APP="$app"`-style pairs (the secret then shows in `ps` for the duration) and note it in the commit.

Expected:
- Both `make` runs print `… ready`.
- The `ls` shows `o.txt`.
- Both `cross=` lines are non-zero, with `AccessDenied`.
- Versioning shows `"Status": "Enabled"`.

- [ ] **Step 6: Idempotence and rotation** (Review Focus 2):

```bash
old="$(env_get OBSIDIAN_S3_SECRET_KEY)"
sed -i '' "s|^OBSIDIAN_S3_SECRET_KEY=.*|OBSIDIAN_S3_SECRET_KEY=$(openssl rand -hex 24)|" .env
make s3-provision app=obsidian versioned=1
aws_as obsidian "$old" s3 ls s3://obsidian/ ; echo "old=$?"
aws_as obsidian "$(env_get OBSIDIAN_S3_SECRET_KEY)" s3 ls s3://obsidian/ ; echo "new=$?"
make s3-provision app=obsidian            # re-run WITHOUT versioned=1
aws_as "$(env_get S3_ADMIN_ACCESS_KEY)" "$(env_get S3_ADMIN_SECRET_KEY)" s3api get-bucket-versioning --bucket obsidian
```
Expected:
- `old=` non-zero (`InvalidAccessKeyId`/`SignatureDoesNotMatch`) and `new=0`.
- Versioning is still `Enabled`, because the existing bucket was not re-created.

- [ ] **Step 7: Rejection cases** (Review Focus 3):

```bash
./scripts/provision-s3.sh 'Jarvis' ; echo $?
./scripts/provision-s3.sh 'x;s3.bucket.delete' ; echo $?
./scripts/provision-s3.sh jarvis 'a b' ; echo $?
./scripts/provision-s3.sh jarvis jarvis 2 ; echo $?
sed -i '' 's|^JARVIS_S3_SECRET_KEY=.*|JARVIS_S3_SECRET_KEY=has space;x|' .env && ./scripts/provision-s3.sh jarvis ; echo $?
sed -i '' "s|^JARVIS_S3_SECRET_KEY=.*|JARVIS_S3_SECRET_KEY=$(openssl rand -hex 24)|" .env   # restore: later steps source .env
```
Expected: every call exits `1` with its `provision-s3.sh:` message. None reaches `docker compose exec`: `s3.bucket.list` via the admin must still show only `obsidian` and `ea-catalogue`.

- [ ] **Step 8: shellcheck + teardown.** Run the shellcheck line (expect no output), then the Test Harness teardown.

- [ ] **Step 9: Commit**

```bash
git add scripts/provision-s3.sh Makefile
git commit -m "feat(s3): generic make s3-provision replaces per-app minio scripts"
```

---

### Task 4: Keycloak `infra` realm, admin UI gate, NGINX vhosts

**Files:**
- Create: `keycloak/realm-import/infra-realm.json`
- Create: `nginx/conf.d/s3.conf`, `nginx/conf.d/s3-admin.conf`
- Delete: `nginx/conf.d/minio.conf`, `nginx/conf.d/minio-famillelallier.conf`, `nginx/conf.d/minio-console.conf`
- Modify: `docker-compose.yml`. Add `oauth2-proxy-infra` after the `oauth2-proxy-ea` service (which ends right before `  nginx:`), and `s3-admin` right after `s3`.

**Interfaces:**
- Consumes: `S3_ADMIN_OAUTH_CLIENT_SECRET`, `S3_ADMIN_OAUTH_COOKIE_SECRET` (Task 1); service `s3` (Task 2).
- Produces:
  - Realm `infra` with groups `s3-admin`/`s3-readwrite`/`s3-readonly`.
  - Client `s3-admin` (confidential, PKCE, callback `https://s3-admin.infra.famillelallier.net/oauth2/callback`).
  - Client `s3-sts` (public, device grant).
  - Services `s3-admin` (`:23646`) and `oauth2-proxy-infra` (`:4180`).
  - Vhosts `s3.infra.famillelallier.net` → `s3:8333` and `s3-admin.infra.famillelallier.net` → `s3-admin:23646` behind `auth_request`.

- [ ] **Step 1: Write the failing check.**

```bash
jq -e '.realm == "infra"' keycloak/realm-import/infra-realm.json; echo "exit=$?"
```
Expected: `Could not open` error, non-zero. (`brew install jq` if jq is missing.)

- [ ] **Step 2: Create `keycloak/realm-import/infra-realm.json`.**

```json
{
  "realm": "infra",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "resetPasswordAllowed": false,
  "groups": [
    { "name": "s3-admin" },
    { "name": "s3-readwrite" },
    { "name": "s3-readonly" }
  ],
  "clients": [
    {
      "clientId": "s3-admin",
      "name": "SeaweedFS admin UI (oauth2-proxy-infra gate)",
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "implicitFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://s3-admin.infra.famillelallier.net"
      },
      "redirectUris": ["https://s3-admin.infra.famillelallier.net/oauth2/callback"],
      "webOrigins": [],
      "protocolMappers": [
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": { "claim.name": "groups", "full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true" }
        },
        {
          "name": "s3-admin-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": { "included.client.audience": "s3-admin", "id.token.claim": "true", "access.token.claim": "true" }
        }
      ]
    },
    {
      "clientId": "s3-sts",
      "name": "SeaweedFS STS (device login for temporary S3 credentials)",
      "protocol": "openid-connect",
      "publicClient": true,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "implicitFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "attributes": { "oauth2.device.authorization.grant.enabled": "true" },
      "redirectUris": [],
      "webOrigins": [],
      "protocolMappers": [
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": { "claim.name": "groups", "full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true" }
        },
        {
          "name": "s3-sts-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": { "included.client.audience": "s3-sts", "id.token.claim": "false", "access.token.claim": "true" }
        }
      ]
    }
  ]
}
```

- [ ] **Step 3: Verify the realm invariants.**

```bash
f=keycloak/realm-import/infra-realm.json
jq -e '.realm=="infra" and (has("users")|not) and ([.clients[]|has("secret")]|any|not)
  and ([.groups[].name]|sort)==["s3-admin","s3-readonly","s3-readwrite"]' $f
jq -e '.clients[]|select(.clientId=="s3-admin")|.redirectUris==["https://s3-admin.infra.famillelallier.net/oauth2/callback"] and .publicClient==false' $f
jq -e '.clients[]|select(.clientId=="s3-sts")|.publicClient and (.standardFlowEnabled|not) and .attributes["oauth2.device.authorization.grant.enabled"]=="true"' $f
jq -e '[.clients[].protocolMappers[]|select(.protocolMapper=="oidc-group-membership-mapper")|.config["full.path"]]==["false","false"]' $f
```
Expected: `true` four times.

- [ ] **Step 4: Add `s3-admin` to `docker-compose.yml`**, directly after the `s3` service:

```yaml
  s3-admin:
    # SeaweedFS's web admin. The OSS build has no login of its own we would
    # want (Keycloak OIDC is Enterprise-only), so it binds infra-net
    # unauthenticated -- the same posture the filer UI (:8888) already has
    # there -- and its only host path is nginx/conf.d/s3-admin.conf behind
    # oauth2-proxy-infra. -allowInsecureBind is how weed admin is told that
    # on purpose. -dataDir=/data is the image's anonymous volume:
    # maintenance-task state is not worth a named one.
    image: chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882
    restart: unless-stopped
    command: ["admin", "-master=s3:9333", "-ip=0.0.0.0", "-allowInsecureBind",
              "-dataDir=/data", "-iceberg.port=0", "-lance.port=0"]
    networks:
      - infra-net
    depends_on:
      s3:
        condition: service_healthy
```

- [ ] **Step 5: Add `oauth2-proxy-infra` to `docker-compose.yml`**, directly after `oauth2-proxy-ea`:

```yaml
  # Third oauth2-proxy, for the SeaweedFS admin UI, against the `infra` realm
  # (nginx/conf.d/s3-admin.conf). Its own container for the reason
  # oauth2-proxy-ea has one: one process, one issuer. Unlike that one it
  # also narrows by group -- s3-admin is root on every bucket.
  oauth2-proxy-infra:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      # Internal infra-net URL + the issuer-verification escape hatch, for
      # the same Keycloak hostname-v2 reason documented on oauth2-proxy above.
      OAUTH2_PROXY_OIDC_ISSUER_URL: http://keycloak:8080/realms/infra
      OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION: "true"
      OAUTH2_PROXY_CLIENT_ID: s3-admin
      # Client secret: generated by Keycloak on realm import, so no :? guard.
      # Cookie key: needed before the first boot, so it has one.
      OAUTH2_PROXY_CLIENT_SECRET: ${S3_ADMIN_OAUTH_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${S3_ADMIN_OAUTH_COOKIE_SECRET:?Set S3_ADMIN_OAUTH_COOKIE_SECRET in .env (openssl rand -base64 32 | tr -- '+/' '-_' -- base64url, not standard base64)}
      OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256
      # Host-scoped, like the ea instance; the distinct name keeps it clear
      # of the jarvis proxy's .famillelallier.net-wide `_oauth2_proxy`.
      OAUTH2_PROXY_COOKIE_NAME: _oauth2_proxy_infra
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_REDIRECT_URL: https://s3-admin.infra.famillelallier.net/oauth2/callback
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      # Only members of this realm group get in; s3-readonly and group-less
      # users get a 403. Read from the `groups` claim (full path off).
      OAUTH2_PROXY_ALLOWED_GROUPS: s3-admin
      OAUTH2_PROXY_UPSTREAMS: static://202
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
    volumes:
      # Same local-CA bundle swap as the other two instances.
      - ${INFRA_DIR:-.}/certs/oauth2proxy-ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro
    networks:
      - infra-net
    depends_on:
      keycloak:
        condition: service_healthy
```

- [ ] **Step 6: Create `nginx/conf.d/s3.conf`.**

```nginx
# SeaweedFS S3 API (and STS, which rides the same port). SigV4 signs the
# Host header; snippets/proxy.conf passes it through unchanged.
server {
    listen 443 ssl;
    server_name s3.infra.famillelallier.net;

    include /etc/nginx/snippets/ssl.conf;

    # S3 uploads can be large; don't buffer or cap the body at the proxy.
    client_max_body_size 0;
    proxy_buffering off;
    proxy_request_buffering off;

    resolver 127.0.0.11 valid=10s;

    location / {
        set $upstream http://s3:8333;
        proxy_pass $upstream;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

- [ ] **Step 7: Create `nginx/conf.d/s3-admin.conf`.** This is the `obsidian.conf` recipe pointed at `oauth2-proxy-infra` and `s3-admin:23646`:

```nginx
# SeaweedFS admin UI. `weed admin` runs unauthenticated on infra-net (its
# OIDC login is Enterprise-only), so this vhost is its only gate: the
# auth_request recipe from obsidian.conf against oauth2-proxy-infra, realm
# `infra`, group `s3-admin`. Everything happens on this one hostname, so
# the cookie is host-scoped and `rd` never leaves it.
server {
    listen 443 ssl;
    server_name s3-admin.infra.famillelallier.net;

    include /etc/nginx/snippets/ssl.conf;

    resolver 127.0.0.11 valid=10s;

    # Object-browser uploads through the UI.
    client_max_body_size 100m;

    location = /oauth2/auth {
        internal;
        set $oauth2_upstream http://oauth2-proxy-infra:4180;
        proxy_pass $oauth2_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;
    }

    location /oauth2/ {
        set $oauth2_upstream http://oauth2-proxy-infra:4180;
        proxy_pass $oauth2_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;
    }

    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in?rd=$request_uri;
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
        proxy_busy_buffers_size 24k;

        set $upstream http://s3-admin:23646;
        proxy_pass $upstream;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

- [ ] **Step 8: Delete the MinIO vhosts.** `git rm nginx/conf.d/minio.conf nginx/conf.d/minio-famillelallier.conf nginx/conf.d/minio-console.conf`

- [ ] **Step 9: Static checks.** Run `docker compose … config -q` and the `nginx -t` line from the Test Harness. Expected: `config` prints nothing, and `nginx -t` ends with `test is successful`.

- [ ] **Step 10: Check `s3-admin` is up and not published.**

```bash
wt_guard && no_other_s3 && docker compose up -d s3 s3-admin
sleep 20; icurl -o /dev/null -w '%{http_code}\n' http://s3-admin:23646/
docker compose ps --format '{{.Service}} {{.Ports}}' s3 s3-admin
```
Expected: `200` or a `302` to its own login-free dashboard. Ports show only container ports (e.g. `8333/tcp`) with **no** `0.0.0.0:` or `127.0.0.1:` host binding. Then run the teardown.

- [ ] **Step 11: Commit**

```bash
git add keycloak/realm-import/infra-realm.json nginx/conf.d/s3.conf nginx/conf.d/s3-admin.conf docker-compose.yml
git commit -m "feat(s3): infra realm, oauth2-proxy-gated admin UI, s3 vhosts"
```

---

### Task 5: DNS, certificates, hosts entries

**Files:**
- Modify: `scripts/dns-provision.sh:79-83`
- Modify: `scripts/gen-certs.sh:2-6,17-24`
- Modify: `scripts/print-hosts-entries.sh:11-12,36-37,55-56`

**Interfaces:**
- Consumes: nothing. Both new names sit under the existing `*.infra.famillelallier.net` wildcard zone and SAN, so **nothing is added**.

- [ ] **Step 1: Write the failing check.** `git grep -n -i minio scripts/dns-provision.sh scripts/gen-certs.sh scripts/print-hosts-entries.sh | wc -l`. Expected: `14`.

- [ ] **Step 2: `scripts/dns-provision.sh`.** Delete lines 79–83: the two `create_zone`/`add_a_record` pairs for `minio.famillelallier.net` and `minio-console.famillelallier.net`, plus the blank line between them. Keep one blank line between the jarvis and chat blocks.

- [ ] **Step 3: `scripts/gen-certs.sh`.**
  - Delete the two `EXTRA_SANS` entries `"minio.famillelallier.net"` and `"minio-console.famillelallier.net"`.
  - Replace header lines 2–6 with:

```bash
# Generates a local CA + leaf cert covering *.infra.famillelallier.net,
# plus pgadmin.famillelallier.net, keycloak.famillelallier.net,
# jarvis.famillelallier.net and chat.famillelallier.net as standalone extra
# SANs (deliberately served outside the .infra. subdomain convention).
```

- [ ] **Step 4: `scripts/print-hosts-entries.sh`.**
  - Delete the `MINIO_HOST=` and `MINIO_CONSOLE_HOST=` lines (11–12), and the four `$IP $MINIO_HOST` / `$IP $MINIO_CONSOLE_HOST` lines (36–37, 55–56).
  - The `*.infra.` hosts are listed individually in this file. Add `S3_HOST="s3.infra.famillelallier.net"` and `S3_ADMIN_HOST="s3-admin.infra.famillelallier.net"` next to the other `*.infra.` host variables.
  - Add `$IP $S3_HOST` and `$IP $S3_ADMIN_HOST` lines in **both** the display list and the `sudo tee` heredoc, next to the other `.infra.` entries.

- [ ] **Step 5: Verify.**

```bash
git grep -n -i minio scripts/dns-provision.sh scripts/gen-certs.sh scripts/print-hosts-entries.sh | wc -l   # expect 0
./scripts/print-hosts-entries.sh 2>/dev/null | grep -E ' s3(-admin)?\.infra\.famillelallier\.net$' | wc -l  # expect >= 2
```
Then run the shellcheck line. Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/dns-provision.sh scripts/gen-certs.sh scripts/print-hosts-entries.sh
git commit -m "chore(s3): drop minio DNS zones, SANs and hosts entries"
```

---

### Task 6: Prometheus job and dashboards

**Files:**
- Modify: `monitoring/prometheus/prometheus.yml:40-48,53-57`
- Modify: `monitoring/grafana/provisioning/dashboards/json/infra-overview.json`, `jarvis.json`, `darkangel.json`

**Interfaces:**
- Consumes: `s3:9324/metrics` (Task 2). Metric names: `SeaweedFS_s3_request_total{type,code,bucket}`, `SeaweedFS_s3_bucket_traffic_{received,sent}_bytes_total{bucket}`, `SeaweedFS_s3_bucket_size_bytes{bucket}`, `SeaweedFS_s3_bucket_object_count{bucket}`, `SeaweedFS_volumeServer_resource{name,type=all|used|free|avail}`.
- Produces: Prometheus job `seaweedfs`.

- [ ] **Step 1: Confirm every metric the dashboards will use exists** (the spec's "empirical first" step):

```bash
wt_guard && no_other_s3 && docker compose up -d s3
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q s3)")" = healthy ]; do sleep 3; done
make s3-provision app=jarvis
aws_as jarvis "$(env_get JARVIS_S3_SECRET_KEY)" s3 cp - s3://jarvis/m.txt <<<'m'
aws_as jarvis "$(env_get JARVIS_S3_SECRET_KEY)" s3 ls s3://obsidian/ || true   # a 403 for the code label
sleep 70   # bucket size gauges refresh once a minute
icurl http://s3:9324/metrics | grep -oE '^SeaweedFS_(s3_request_total|s3_bucket_traffic_received_bytes_total|s3_bucket_traffic_sent_bytes_total|s3_bucket_size_bytes|s3_bucket_object_count|volumeServer_resource)\{[^}]*\}' | sort -u
```
Expected:
- All six metric names appear.
- `s3_request_total` carries `bucket="jarvis"`, a numeric `code="200"`, and a `code="403"` series.
- `volumeServer_resource` carries `type="all"`, `"used"` and `"free"`.

If a name or label differs, **stop and update the substitution table in Step 3 to the real names** before editing anything.

- [ ] **Step 2: `prometheus.yml`.**
  - Replace lines 40–48 (jobs `minio` and `minio-bucket`) with:

```yaml
  - job_name: seaweedfs
    # weed server -metricsPort serves every component (master, volume,
    # filer, s3) on this one port; default /metrics path.
    static_configs:
      - targets: ["s3:9324"]
```
  - In the openbao comment, replace `the same` / `# posture as minio's public metrics.` with `the same` / `# posture as the seaweedfs job's unauthenticated /metrics.`, keeping the wrapping.

- [ ] **Step 3: Rewrite the dashboards with exact substitutions.** Save as `$CLAUDE_JOB_DIR/tmp/dash.py` (or any scratch path; do not commit it) and run it with `python3 <path>` from the worktree root. It edits the raw text, so formatting is untouched. It fails loudly if any `minio` string survives or the JSON stops parsing.

```python
import json, re, pathlib
D = pathlib.Path("monitoring/grafana/provisioning/dashboards/json")
esc = lambda s: json.dumps(s)[1:-1]   # decoded string -> its form inside a JSON string

VOL = 'sum(SeaweedFS_volumeServer_resource{type="%s"})'
common = [
    ('up{job="minio"}', 'up{job="seaweedfs"}'),
    ('minio_cluster_capacity_usable_total_bytes{job="minio"}', VOL % "all"),
    ('minio_cluster_capacity_usable_free_bytes{job="minio"}', VOL % "free"),
    ('minio_cluster_usage_total_bytes{job="minio"}', VOL % "used"),
    ('sum by (name) (rate(container_cpu_usage_seconds_total{name=~".*minio.*"}[5m]))',
     'sum by (name) (rate(container_cpu_usage_seconds_total{name=~".*-s3-[0-9]+"}[5m]))'),
    ('sum by (name) (container_memory_working_set_bytes{name=~".*minio.*", image!=""})',
     'sum by (name) (container_memory_working_set_bytes{name=~".*-s3-[0-9]+", image!=""})'),
    ('{compose_service="minio"}', '{compose_service="s3"}'),
]
def bucket_subs(b):
    sel = 'job="minio-bucket", bucket="%s"' % b
    return [
        ('sum(rate(minio_bucket_requests_4xx_errors_total{%s}[5m])) + sum(rate(minio_bucket_requests_5xx_errors_total{%s}[5m]))' % (sel, sel),
         'sum(rate(SeaweedFS_s3_request_total{bucket="%s", code=~"[45].."}[5m]))' % b),
        ('sum(rate(minio_bucket_requests_4xx_errors_total{%s}[5m]))' % sel,
         'sum(rate(SeaweedFS_s3_request_total{bucket="%s", code=~"4.."}[5m]))' % b),
        ('sum(rate(minio_bucket_requests_5xx_errors_total{%s}[5m]))' % sel,
         'sum(rate(SeaweedFS_s3_request_total{bucket="%s", code=~"5.."}[5m]))' % b),
        ('sum by (api) (rate(minio_bucket_requests_total{%s}[5m]))' % sel,
         'sum by (type) (rate(SeaweedFS_s3_request_total{bucket="%s"}[5m]))' % b),
        ('sum(rate(minio_bucket_requests_total{%s}[5m]))' % sel,
         'sum(rate(SeaweedFS_s3_request_total{bucket="%s"}[5m]))' % b),
        ('rate(minio_bucket_traffic_received_bytes{%s}[5m])' % sel,
         'rate(SeaweedFS_s3_bucket_traffic_received_bytes_total{bucket="%s"}[5m])' % b),
        ('rate(minio_bucket_traffic_sent_bytes{%s}[5m])' % sel,
         'rate(SeaweedFS_s3_bucket_traffic_sent_bytes_total{bucket="%s"}[5m])' % b),
        ('minio_bucket_usage_total_bytes{%s}' % sel, 'SeaweedFS_s3_bucket_size_bytes{bucket="%s"}' % b),
        ('minio_bucket_usage_object_total{%s}' % sel, 'SeaweedFS_s3_bucket_object_count{bucket="%s"}' % b),
    ]
files = {
    "infra-overview.json": [
        ('minio_cluster_capacity_usable_total_bytes - minio_cluster_capacity_usable_free_bytes', VOL % "used"),
        ('minio_cluster_capacity_usable_total_bytes', VOL % "all"),
        ('sum(rate(minio_s3_requests_incoming_total[5m]))', 'sum(rate(SeaweedFS_s3_request_total[5m]))'),
        ('sum(rate(minio_s3_requests_rejected_auth_total[5m]))', 'sum(rate(SeaweedFS_s3_request_total{code="403"}[5m]))'),
        ('sum(rate(minio_s3_traffic_received_bytes[5m]))', 'sum(rate(SeaweedFS_s3_bucket_traffic_received_bytes_total[5m]))'),
        ('sum(rate(minio_s3_traffic_sent_bytes[5m]))', 'sum(rate(SeaweedFS_s3_bucket_traffic_sent_bytes_total[5m]))'),
        ('"title": "MinIO",', '"title": "Object storage (SeaweedFS)",'),
        ('"title": "Usable capacity used"', '"title": "Volume disk used"'),
    ],
    "jarvis.json": bucket_subs("jarvis") + common + [
        ('"title": "MinIO (bucket jarvis)"', '"title": "S3 (bucket jarvis)"'),
        ('"title": "MinIO scrape"', '"title": "S3 scrape"'),
        ('"title": "MinIO container CPU"', '"title": "S3 container CPU"'),
        ('"title": "MinIO container memory"', '"title": "S3 container memory"'),
        ('"title": "MinIO logs"', '"title": "S3 logs"'),
        ('"tags": ["jarvis", "app", "minio"]', '"tags": ["jarvis", "app", "s3"]'),
    ],
    "darkangel.json": bucket_subs("darkangel-files") + [
        ('"title": "MinIO (bucket darkangel-files)"', '"title": "S3 (bucket darkangel-files)"'),
    ],
}
for name, subs in files.items():
    p = D / name
    raw = p.read_text()
    for old, new in subs:
        # Raw JSON-syntax pairs (titles, tags) start with '"'; the rest are expr values.
        o, n = (old, new) if old.startswith('"') else (esc(old), esc(new))
        raw = raw.replace(o, n)   # absent = a panel this dashboard doesn't have; the minio check below catches real misses
    raw = raw.replace('"legendFormat": "{{api}}"', '"legendFormat": "{{type}}"')
    json.loads(raw)
    left = [l for l in raw.splitlines() if re.search("minio", l, re.I)]
    if left:
        raise SystemExit(f"{name}: minio still present:\n" + "\n".join(left))
    p.write_text(raw)
    print("ok", name)
```
Expected: `ok infra-overview.json`, `ok jarvis.json`, `ok darkangel.json`.

- [ ] **Step 4: Static checks.**

```bash
docker run --rm --entrypoint promtool \
  -v "$PWD/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$PWD/monitoring/prometheus/targets:/etc/prometheus/targets:ro" \
  prom/prometheus check config /etc/prometheus/prometheus.yml
git grep -n -i minio -- monitoring | wc -l
```
Expected: `SUCCESS` from promtool, then `0`.

- [ ] **Step 5: Check every new expression against live data.** With the Step 1 `s3` still up, query each new expr through a throwaway Prometheus scraping it:

```bash
cat > "$CLAUDE_JOB_DIR/tmp/p.yml" <<'Y'
global: { scrape_interval: 5s }
scrape_configs: [ { job_name: seaweedfs, static_configs: [ { targets: ["s3:9324"] } ] } ]
Y
docker run -d --name s3-promtest --network infra-net -v "$CLAUDE_JOB_DIR/tmp/p.yml:/etc/prometheus/prometheus.yml:ro" prom/prometheus
sleep 40
for q in 'up{job="seaweedfs"}' 'sum(SeaweedFS_volumeServer_resource{type="used"})' \
         'SeaweedFS_s3_bucket_size_bytes{bucket="jarvis"}' 'sum(rate(SeaweedFS_s3_request_total{bucket="jarvis"}[5m]))'; do
  icurl -G http://s3-promtest:9090/api/v1/query --data-urlencode "query=$q" | grep -o '"result":\[[^]]*' | head -c 120; echo
done
docker rm -f s3-promtest
```
Expected: each line shows a non-empty `"result":[{…"value":[…` (not `"result":[`). Then run the teardown.

- [ ] **Step 6: Commit**

```bash
git add monitoring/prometheus/prometheus.yml monitoring/grafana/provisioning/dashboards/json/
git commit -m "feat(monitoring): scrape SeaweedFS and port S3 dashboard panels"
```

---

### Task 7: Documentation and stray comments

**Files:**
- Modify: `CLAUDE.md` (lines 20–26, 60–63, 145–152, 192–196, 432–446, 465–469, 880–884)
- Modify: `keycloak/CLAUDE.md:34-39` plus a new `infra` realm section at the end
- Modify: `scripts/CLAUDE.md:9,38`, `README.md` (5, 15, 50, 76, 139–141, 287–310, 373, 554, 1049, plus a new STS section), `AGENTS.md:4,82`
- Modify: `docker-compose.portainer.yml:8-9`, `scripts/check-docker.sh:207`, `scripts/migrate-volumes.sh:7,78`, `openbao/config.hcl:22`

**Interfaces:** none (docs only).

- [ ] **Step 1: Write the failing check.** `git grep -n -i minio -- ':!docs/superpowers' | wc -l`. Expected: a positive count (every remaining hit is in the files above).

- [ ] **Step 2: One-word swaps** (keep surrounding wrapping; reflow the paragraph only if a line gets absurdly short):
  - `README.md:5`, `README.md:15`, `AGENTS.md:4`: `MinIO` → `SeaweedFS (S3)`.
  - `README.md:50`: `Keycloak, MinIO, Grafana or RabbitMQ data` → `Keycloak, object-store, Grafana or RabbitMQ data`.
  - `README.md:76`: `` `MINIO_ROOT_PASSWORD`, `` → `` `S3_ADMIN_SECRET_KEY`, ``.
  - `README.md:373`: `MINIO_ROOT_PASSWORD=new-value` → `S3_ADMIN_SECRET_KEY=new-value`.
  - `README.md:554`: `MinIO,` → `SeaweedFS (\`s3:9324/metrics\`),`.
  - `README.md:1049`: `keycloak, minio, rabbitmq` → `keycloak, s3, s3-admin, rabbitmq`.
  - `AGENTS.md:82`: `` /`minio`/ `` → `` /`s3`/`s3-admin`/ ``.
  - `scripts/CLAUDE.md:9`: `MinIO and RabbitMQ` → `SeaweedFS and RabbitMQ`.
  - `scripts/CLAUDE.md:38`: `an empty MinIO` → `an empty object store`.
  - `scripts/check-docker.sh:207`: `MinIO and RabbitMQ` → `SeaweedFS and RabbitMQ`.
  - `scripts/migrate-volumes.sh:7`: `an empty MinIO` → `an empty object store`.
  - `scripts/migrate-volumes.sh:78`: `Postgres/MinIO/RabbitMQ` → `Postgres/SeaweedFS/RabbitMQ`.
  - `docker-compose.portainer.yml:9`: `same moving-tag tradeoff as minio/dns in docker-compose.yml` → `same moving-tag tradeoff as dns in docker-compose.yml`.
  - `openbao/config.hcl:22`: `# same posture as minio's MINIO_PROMETHEUS_AUTH_TYPE=public: read-only` → `# same posture as the seaweedfs /metrics endpoint: read-only`.
  - `keycloak/CLAUDE.md:37`: `same-network reason the \`minio\` service avoids \`MINIO_SERVER_URL\`` → `same-network reason every infra-net client uses service names`.
  - `CLAUDE.md:882`–`883`: `the same posture as` / `MinIO's public metrics)` → `the same posture as` / `SeaweedFS's /metrics)`.

- [ ] **Step 3: `CLAUDE.md` structural edits.**
  - **Lines 20–26:** in the `check-env` target list, replace `` `keycloak-seed-users` and `obsidian-minio` `` with `` `keycloak-seed-users` and `s3-provision` ``.
  - **Lines 60–63:** replace the `minio` bullet with:

```markdown
- **`s3`** — `chrislusf/seaweedfs:4.47`, pinned by tag *and* digest like
  `neo4j`. One `weed server -s3` container; publishes no host
  port. S3 (and STS) on `:8333`, fronted by NGINX at
  `s3.infra.famillelallier.net`; apps on `infra-net` use `http://s3:8333`.
  Auth is on from first boot via the `S3_ADMIN_*` env identity — SeaweedFS
  serves **anonymously** when no identity exists, so never remove it.
  Per-app bucket-scoped identities come from `make s3-provision
  app=<name> [bucket=] [versioned=1]` (`scripts/provision-s3.sh`); the IAM
  config (Keycloak OIDC provider, STS roles) is `seaweedfs/iam.json.tmpl`,
  rendered into the container's `/tmp` at start. The filer (`:8888`) and
  master (`:9333`) UIs are unauthenticated and must never get a host path.
  Metrics on `:9324`. Break glass: `docker compose exec s3 weed shell
  -master=s3:9333`.
- **`s3-admin`** — `weed admin` (same image), at
  `s3-admin.infra.famillelallier.net`. It has no login of its own (OSS
  SeaweedFS's OIDC is Enterprise-only) and runs `-allowInsecureBind` on
  `infra-net`; `nginx/conf.d/s3-admin.conf` gates it through a **third**
  oauth2-proxy, `oauth2-proxy-infra` (realm `infra`, client `s3-admin`,
  `OAUTH2_PROXY_ALLOWED_GROUPS: s3-admin`). Only `s3-admin` members get in,
  as full admins; there is no read-only UI role.
```
  - **Lines 145–152**, the tail of the Obsidian paragraph from `Vault data is synced into MinIO` to `other devices sync from.`: replace with:

```markdown
  Vault data is synced into the S3 store (bucket `obsidian`, versioned) by
  the in-app **Remotely Save** plugin against `http://s3:8333`, using the
  identity `obsidian` scoped to that bucket
  (`make s3-provision app=obsidian versioned=1`). The working copy stays on
  the `obsidian-config` volume: Obsidian watches the filesystem, so a
  FUSE/s3fs mount of the bucket as `/config` is not an option (it also
  needs `SYS_ADMIN`). The bucket is the durable copy and the one other
  devices sync from.
```
  - **Lines 192–196**, the hostname list: replace `` MinIO / (`minio.famillelallier.net` / `minio-console.famillelallier.net`), `` with `` SeaweedFS (`s3.infra.famillelallier.net`, admin UI `s3-admin.infra.famillelallier.net`), ``.
  - **Lines 432–446**, single-ingress rule:
    - In both backend lists, replace `` `minio` `` with `` `s3`, `s3-admin` ``.
    - In the port-80/443 upstream list, replace `` `minio:9000` / `minio:9001` `` with `` `s3:8333`, `s3-admin:23646` (behind `oauth2-proxy-infra`) ``.
  - **Lines 465–469**, the "Do not add a `ports:` entry" list: replace `` `minio`, `` with `` `s3`, `s3-admin`, `oauth2-proxy-infra`, ``.

- [ ] **Step 4: Append to `keycloak/CLAUDE.md`:**

```markdown
## Infra: SeaweedFS admin gate and STS (realm `infra`)

`keycloak/realm-import/infra-realm.json` — the home for infra tooling SSO.
No client secrets and no `users` array in git; create humans in the console
with a **verified email** (oauth2-proxy rejects an unverified one with a
bare 500 on `/oauth2/callback`) and add them to a group.

- Groups `s3-admin`, `s3-readwrite`, `s3-readonly`, emitted as the `groups`
  claim by a group-membership mapper with **Full group path off** — both
  oauth2-proxy (`OAUTH2_PROXY_ALLOWED_GROUPS`) and SeaweedFS's STS
  `roleMapping` match the bare name, and `/s3-admin` would match neither.
- `s3-admin`: confidential, PKCE S256, one exact redirect URI
  `https://s3-admin.infra.famillelallier.net/oauth2/callback`. Its secret
  goes into `S3_ADMIN_OAUTH_CLIENT_SECRET` after the first deploy
  (`check-env` warns until then; `oauth2-proxy-infra` crash-loops).
- `s3-sts`: public, device authorization grant only. Its tokens are
  exchanged at `https://s3.infra.famillelallier.net` for temporary keys
  (`AssumeRoleWithWebIdentity`; roles in `seaweedfs/iam.json.tmpl`). The
  STS side trusts only `iss == https://keycloak.famillelallier.net/realms/infra`
  and fetches JWKS from the internal `http://keycloak:8080/...` URL, so `s3`
  needs no CA trust. `roleMapping` only picks which role a request names by
  default — it does not gate which role may be assumed; that gate is each
  role's trust policy in `seaweedfs/iam.json.tmpl`, which requires both that
  issuer and a matching `groups` claim (`s3-admin` for `S3AdminRole`,
  `s3-readwrite` or above for `S3WriteRole`, `s3-readonly` or above for
  `S3ReadOnlyRole`). A user in no group gets no credentials for any role.

`--import-realm` only seeds a realm that does not exist yet — edit the live
realm in the console too after changing this file.
```

- [ ] **Step 5: `README.md` sections.**
  - **Lines 139–141:** replace with:

```markdown
S3 (SeaweedFS): API `https://s3.infra.famillelallier.net` (apps on
`infra-net`: `http://s3:8333`), admin UI
`https://s3-admin.infra.famillelallier.net` (Keycloak realm `infra`, group
`s3-admin`)
```
  - **Lines 287–310:** replace the whole "Obsidian vaults in MinIO" section with:

~~~markdown
### Obsidian vaults in S3

The browser Obsidian keeps its working copy on the `obsidian-config`
volume and syncs it into the S3 bucket `obsidian` with the Remotely Save
plugin. One-time setup, after `make up`:

1. Set `OBSIDIAN_S3_SECRET_KEY` in `.env` (`openssl rand -hex 24`),
   `make vault-seed`, then `make s3-provision app=obsidian versioned=1`
   (creates the versioned bucket and the identity `obsidian`, scoped to it;
   safe to re-run).
2. In `https://obsidian.infra.famillelallier.net`, create or open a vault,
   then **Settings → Community plugins → Browse → Remotely Save → Install →
   Enable**.
3. Remotely Save settings → **S3 or compatible**:
   - Endpoint: `http://s3:8333`
   - Region: `us-east-1`
   - Access Key ID: `obsidian`
   - Secret Access Key: your `OBSIDIAN_S3_SECRET_KEY`
   - Bucket: `obsidian`
   - S3 URL style: **Path Style**
   - Bypass CORS: on
   - Then **Check** the connection, and set a schedule (e.g. every 5 min).

Other devices (phone, laptop) can sync the same vault with the same
settings, using `https://s3.infra.famillelallier.net` as the endpoint.

### S3 credentials for humans (STS)

Members of the `infra` realm groups `s3-readonly` / `s3-readwrite` /
`s3-admin` get temporary keys (1 h) instead of a static one:

```bash
KC=https://keycloak.famillelallier.net/realms/infra/protocol/openid-connect
curl -s -d client_id=s3-sts "$KC/auth/device"          # open verification_uri_complete, log in
curl -s -d client_id=s3-sts -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
  -d device_code=<device_code> "$KC/token"              # -> access_token
aws sts assume-role-with-web-identity --endpoint-url https://s3.infra.famillelallier.net \
  --role-arn arn:aws:iam::role/S3ReadOnlyRole --role-session-name "$USER" \
  --web-identity-token <access_token>                   # -> export the three keys it returns
```

Use `S3WriteRole` / `S3AdminRole` for the other groups; each role's trust
policy requires both the `infra` issuer and a matching `groups` claim
(`s3-admin` → `S3AdminRole` and below, `s3-readwrite` → `S3WriteRole` and
`S3ReadOnlyRole`, `s3-readonly` → `S3ReadOnlyRole` only), so a user in no
group, or asking for a role above their group, is refused.
~~~

- [ ] **Step 6: Verify.**

```bash
git grep -n -i minio -- ':!docs/superpowers' ; echo "hits=$?"
```
Expected: no output and `hits=1` (`git grep` exits 1 on no match). Then run shellcheck (no output), plus `compose config -q` and `nginx -t` (unchanged results).

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md keycloak/CLAUDE.md scripts/CLAUDE.md README.md AGENTS.md docker-compose.portainer.yml scripts/check-docker.sh scripts/migrate-volumes.sh openbao/config.hcl
git commit -m "docs(s3): document SeaweedFS, the infra realm and STS; drop minio"
```

---

### Task 8: Cutover and acceptance (after merge, on the live stack)

This is not a coding task. It runs **from the main checkout after the PR merges**, against the live stack, and needs the human for:
- the destructive orphan cleanup (confirm first)
- the Keycloak console steps
- a browser login

S3-backed features in each app are down from Step 1 until that app's consumer PR (Step 7) ships.

**Files:** none in this repo.

- [ ] **Step 1: Merge and deploy.**
  1. Merge the PR, then `git checkout main && git pull --ff-only`.
  2. Add the new keys to `.env`, using the recipes in `.env.example`. `make check-env` lists what is missing.
  3. Run `make vault-seed`, because `make up` re-renders `.env` from OpenBao and would otherwise drop them.
  4. Run `make up`. Keycloak imports realm `infra` on this boot.

  Expected: `check-env` passes with the single `S3_ADMIN_OAUTH_CLIENT_SECRET` warning, and `s3` goes healthy.
- [ ] **Step 2: Keycloak console.**
  1. Realm `infra` → Clients → `s3-admin` → Credentials. Copy the secret into `S3_ADMIN_OAUTH_CLIENT_SECRET`.
  2. Create your user with **Email verified** on and add it to `s3-admin`.
  3. For the acceptance tests, create three more users: one in `s3-readwrite`, one in `s3-readonly`, one in no group.
  4. Run `make vault-seed && make up`.
- [ ] **Step 3: Orphans (destructive, ask the human first).**

```bash
docker ps -a --filter name=minio --format '{{.Names}} {{.Image}}'   # look before deleting
docker rm -f <that container>
docker volume rm infra_minio-data
```
- [ ] **Step 4: Provision the four apps.**

```bash
make s3-provision app=jarvis
make s3-provision app=obsidian versioned=1
make s3-provision app=ea bucket=ea-catalogue
make s3-provision app=darkangel bucket=darkangel-files
```
- [ ] **Step 5: Certificates and DNS.** Run `./scripts/gen-certs.sh --force`: it keeps the local CA and drops the minio SANs. Then `docker compose restart nginx oauth2-proxy oauth2-proxy-ea oauth2-proxy-infra`. In Technitium (`http://<LAN_IP>:5380`), delete zones `minio.famillelallier.net` and `minio-console.famillelallier.net`.
- [ ] **Step 6: Acceptance.** Use `aws_as`/`icurl` from the Test Harness, which work from the main checkout too; do **not** use `wt_guard` here.
  - A1: `icurl -o /dev/null -w '%{http_code}' http://s3:8333/` → `403`.
  - A2: each of the four identities can put/get/list in its own bucket and gets `AccessDenied` on `obsidian` (and `jarvis` on `ea-catalogue`).
  - A3: rotate `JARVIS_S3_SECRET_KEY` and re-provision. The old secret is rejected, the new one works. Update Jarvis with the new value.
  - A4: `s3api get-bucket-versioning --bucket obsidian` → `Enabled`.
  - A5: through NGINX, as `jarvis`: `dd if=/dev/zero bs=1m count=1100 | docker run --rm -i -e AWS_ACCESS_KEY_ID=jarvis -e AWS_SECRET_ACCESS_KEY="$(env_get JARVIS_S3_SECRET_KEY)" -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli --endpoint-url https://s3.infra.famillelallier.net --no-verify-ssl s3 cp - s3://jarvis/big.bin` succeeds. Then delete `big.bin`.
  - A6: `https://s3-admin.infra.famillelallier.net` redirects to Keycloak.
    - The `s3-admin` user lands in the UI.
    - The `s3-readonly` user and the no-group user get oauth2-proxy's 403.
    - `nc -z <LAN_IP> 8888 9333 9324 23646` from another machine all fail.
  - A7: STS, following the README flow.
    - An `s3-readonly` token gets keys that can `ls` but get `AccessDenied` on `cp`.
    - An `s3-readwrite` token can `cp`.
    - A no-group token gets no credentials.
    - A token from realm `ea` (client `ea-spa` or any `ea` login) is rejected.
  - A8: after A7, re-run A2 for one app. Static keys still behave.
  - A9: in Grafana, the `infra-overview` S3 row and the `jarvis`/`darkangel` S3 rows all show data. Prometheus target `seaweedfs` is `UP`.
  - A10: `git grep -i minio -- ':!docs/superpowers'` → nothing.
- [ ] **Step 7: Consumer PRs** (one per repo, not this repo):
  - **Jarvis:** endpoint `http://s3:8333`, access key `jarvis`, `MINIO_*` env keys renamed `S3_*`; drop the `.env.example` note about reusing MinIO root credentials.
  - **EA:** `EA_S3_ENDPOINT` default `s3:8333`, access key `ea` (was `ea-api`); update comments naming MinIO / `ea-api`; copy `EA_S3_SECRET_KEY`.
  - **DarkAngel:** endpoint `http://s3:8333`, access key `darkangel`; delete its `make minio` target.
  - **Obsidian (Remotely Save, no repo):** endpoint `http://s3:8333` inside the container, `https://s3.infra.famillelallier.net` elsewhere, access key `obsidian`; let it re-push the vault.
