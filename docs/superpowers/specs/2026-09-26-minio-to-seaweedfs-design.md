# Replace MinIO with SeaweedFS

Status: draft 2026-09-26

## Goal

Swap the shared object store from MinIO to SeaweedFS, like for like: a
maintained S3 server that consumers talk to exactly as before. MinIO is a
dead end here — no new images (the service is pinned to
`RELEASE.2025-09-07T16-13-09Z` on quay.io), and the community console lost
its admin features. No SeaweedFS-only feature (filer mounts, tiering,
S3 Tables) is in scope.

Keycloak becomes the identity provider for the store's humans: the admin
UI logs in through it, and people get temporary S3 credentials from it
(STS). Apps keep static per-app keys.

## Decisions

- **Fresh start, no data migration.** `minio-data` is abandoned; apps
  re-upload. Accepted cost: the Obsidian bucket's version history is lost
  (the vault itself re-pushes from the `obsidian-config` volume).
- **Rename everywhere.** Service `s3`, endpoint `http://s3:8333`, public
  names under `.infra.`, env keys `S3_*`. No `minio` alias is kept.
- **Layout A**: `weed server -s3` in one container (`s3`) plus `weed admin`
  in a second (`s3-admin`). Rejected: `weed mini` (documented as a
  quick-start profile, auto-tunes volume sizes) and a fully split
  master/volume/filer/s3 topology (scale-out we don't need on one Mac).
- **One generic provisioning target** replaces the per-app scripts, mirroring
  Postgres's `provision-app`. Every app, Jarvis included, gets its own
  bucket-scoped identity; nobody uses the admin credentials.
- **Keycloak, both ways, in a new `infra` realm.** Native admin-UI OIDC
  (no oauth2-proxy, no local UI password) and STS
  `AssumeRoleWithWebIdentity` for humans. The realm is the home for future
  infra tooling SSO. Rejected: reusing the `ea` realm (ties storage admin to
  one app's realm) and a `seaweedfs`-only realm.

## Constraints found

- SeaweedFS S3 runs in **allow-all mode when no identity is configured**;
  authentication switches on globally once one identity exists. The admin
  identity must therefore exist from the very first boot.
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` on the container provide it
  (lowest-priority credential source, below config file and filer).
- Identities created with `weed shell s3.configure ... -apply` or the admin
  UI are stored in the filer, so provisioning stays imperative and
  idempotent; there is no credentials file to template from `.env`.
- The filer UI (`:8888`) and master UI (`:9333`) are unauthenticated and can
  read/delete every object. They must never be reachable from the host.
- S3 SigV4 signs the `Host` header; `nginx/snippets/proxy.conf` already
  passes it through unchanged (MinIO works behind it today).
- Dropping `minio` from `docker-compose.yml` makes its container and volume
  orphans: redeploys don't remove them, and `make clean` (`down -v`) only
  removes volumes the compose file still declares.
- Static identities and the advanced IAM config (`-s3.iam.config`: OIDC
  providers, STS, roles) are documented to coexist on one S3 server.
- The IAM config holds the STS signing key, so it cannot be committed as-is.
- Keycloak's issuer is the external `https://keycloak.famillelallier.net`
  (`KC_HOSTNAME`), which from inside `infra-net` resolves to `nginx` via its
  network alias and presents the local CA. STS only compares the `iss`
  string and can fetch JWKS from the internal
  `http://keycloak:8080/realms/infra/...` URL, so `s3` needs no CA trust.
  The admin UI does full discovery against the issuer, so `s3-admin` does.
- `--import-realm` seeds `keycloak/realm-import/*.json` only for realms that
  don't exist yet; later edits to the file must be repeated in the console.
- EA and DarkAngel each run a throwaway MinIO in their own repos for
  integration tests. Those never touch Infra and stay as they are.

## Design

### 1. Services (`docker-compose.yml`)

`minio` and the `minio-data` volume are deleted. Added:

```yaml
s3:
  image: chrislusf/seaweedfs:<version>@sha256:<digest>
  restart: unless-stopped
  # Renders the IAM template (section 5) to /tmp, then execs weed.
  entrypoint: ["/bin/sh", "-c"]
  command:
    - >-
      sed "s|__S3_STS_SIGNING_KEY__|$$S3_STS_SIGNING_KEY|"
      /etc/seaweedfs/iam.json.tmpl > /tmp/iam.json &&
      exec weed server -dir=/data -s3 -s3.iam.config=/tmp/iam.json
      -metricsPort=9324
  environment:
    AWS_ACCESS_KEY_ID: ${S3_ADMIN_ACCESS_KEY:?Set S3_ADMIN_ACCESS_KEY in .env}
    AWS_SECRET_ACCESS_KEY: ${S3_ADMIN_SECRET_KEY:?Set S3_ADMIN_SECRET_KEY in .env}
    S3_STS_SIGNING_KEY: ${S3_STS_SIGNING_KEY:?Set S3_STS_SIGNING_KEY in .env}
  volumes:
    - s3-data:/data
    - ${INFRA_DIR:-.}/seaweedfs/iam.json.tmpl:/etc/seaweedfs/iam.json.tmpl:ro
  networks: [infra-net]
  healthcheck: # HTTP probe of the S3 listener on :8333

s3-admin:
  image: <same pin>
  restart: unless-stopped
  command: ["admin", "-masters=s3:9333"]
  environment:
    WEED_ADMIN_OIDC_ENABLED: "true"
    WEED_ADMIN_OIDC_ISSUER: https://keycloak.famillelallier.net/realms/infra
    WEED_ADMIN_OIDC_CLIENT_ID: s3-admin
    WEED_ADMIN_OIDC_CLIENT_SECRET: ${S3_ADMIN_OIDC_CLIENT_SECRET}   # no :? guard
    WEED_ADMIN_OIDC_REDIRECT_URL: https://s3-admin.infra.famillelallier.net/login/oidc/callback
    WEED_ADMIN_OIDC_SCOPES: openid,profile,email
    WEED_ADMIN_OIDC_ADMIN_GROUPS: s3-admin
    WEED_ADMIN_OIDC_READONLY_GROUPS: s3-readonly
  volumes:
    # Same bundle the oauth2-proxy containers use: public roots + our CA.
    - ${INFRA_DIR:-.}/certs/oauth2proxy-ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro
  networks: [infra-net]
  depends_on:
    s3: { condition: service_started }
    keycloak: { condition: service_healthy }
```

- `$$` keeps Compose from interpolating the signing key into the command
  line; the shell reads it from the environment. The rendered file lives in
  the container's `/tmp`, never on the host.
- No `-adminUser` / `-adminPassword`: Keycloak is the only UI login. Break
  glass when Keycloak is down: `docker compose exec s3 weed shell`.
- No `WEED_ADMIN_OIDC_ROLE_MAPPING_DEFAULT_ROLE`: a realm user in neither
  group gets no UI access. Verify at implementation that the pinned version
  denies (not defaults to readonly) when the variable is unset; set it
  explicitly to a deny value if one exists.
- `S3_ADMIN_OIDC_CLIENT_SECRET` has no `:?` guard: Keycloak generates it on
  realm import, after the first deploy (same rule as the oauth2-proxy client
  secrets in `CLAUDE.md`).

- Pinned by tag **and** digest, like `neo4j`: a storage-format change must
  not ride along with a redeploy.
- Neither service has a `ports:` key (single-ingress rule). `s3` and
  `s3-admin` join the "do not add `ports:`" list in `CLAUDE.md`.
- `:8333` is SeaweedFS's default S3 port; kept to avoid a flag.
- The exact healthcheck command depends on what the pinned image ships
  (`wget`/`curl`); pick it when pinning.

### 2. NGINX, DNS, certificates

| Old | New |
|---|---|
| `minio.conf` (`minio.infra.famillelallier.net`) and `minio-famillelallier.conf` (`minio.famillelallier.net`) → `minio:9000` | `s3.conf`: `s3.infra.famillelallier.net` → `http://s3:8333` |
| `minio-console.conf` (`minio-console.famillelallier.net`) → `minio:9001` | `s3-admin.conf`: `s3-admin.infra.famillelallier.net` → `http://s3-admin:23646` |

- `s3.conf` keeps `client_max_body_size 0`, `proxy_buffering off`,
  `proxy_request_buffering off` (large uploads).
- Both keep the `resolver 127.0.0.11` + `set $upstream` pattern.
- The `*.infra.` wildcard covers both names: **no new DNS zone, no new cert
  SAN**. Removed: the `minio.famillelallier.net` /
  `minio-console.famillelallier.net` zones in `scripts/dns-provision.sh`,
  their SANs in `scripts/gen-certs.sh` (and its header comment), and their
  lines in `scripts/print-hosts-entries.sh`.
- `dns-provision.sh` never deletes zones, so the two existing zones are
  removed once by hand in Technitium (cutover step 4).
- The admin UI is protected by its native Keycloak login (section 5). No
  oauth2-proxy and no `auth_request` on `s3-admin.conf`.
- STS (`AssumeRoleWithWebIdentity`) is served on the S3 port, so it rides
  `s3.conf` — no extra vhost.

### 3. Provisioning

`scripts/provision-s3.sh`, exposed as:

```
make s3-provision app=<name> [bucket=<bucket>] [versioned=1]
```

- Runs `check-env` first (added to the `CLAUDE.md` list of targets that do).
- `bucket` defaults to `app`. The identity and access key are both `app`;
  the secret is `<APP>_S3_SECRET_KEY` from Infra's `.env` (`APP` =
  uppercased `app`). The script dies if that variable is unset.
- Executes in the `s3` container via `docker compose exec -T` + stdin
  heredoc, same shape as the current MinIO scripts:
  1. `s3.bucket.create -name <bucket>`, tolerating "already exists".
  2. `s3.configure -user <app> -access_key <app> -secret_key <secret>
     -buckets <bucket> -actions Read,Write,List,Tagging -apply` — scoped to
     the one bucket, never `Admin`.
  3. With `versioned=1`: enable versioning on the bucket. First
     implementation step checks whether the pinned version's `weed shell`
     has a bucket-versioning command. If not, send a signed
     `PutBucketVersioning` from a throwaway `amazon/aws-cli` container on
     `infra-net` with the admin credentials, passed on stdin, not argv
     (same reasoning as `portainer-stack.sh`'s `curlimages/curl`).
- Idempotent; re-running rotates the secret (acceptance check below).

The four invocations:

| Invocation | Identity / access key | Bucket | Secret |
|---|---|---|---|
| `app=jarvis` | `jarvis` (was: MinIO root) | `jarvis` | `JARVIS_S3_SECRET_KEY` |
| `app=obsidian versioned=1` | `obsidian` | `obsidian` | `OBSIDIAN_S3_SECRET_KEY` |
| `app=ea bucket=ea-catalogue` | `ea` (was `ea-api`) | `ea-catalogue` | `EA_S3_SECRET_KEY` |
| `app=darkangel bucket=darkangel-files` | `darkangel` (was `darkangel-api`) | `darkangel-files` | `DARKANGEL_S3_SECRET_KEY` |

Bucket names are unchanged, so consumer bucket defaults stay valid.

Deleted: `scripts/provision-obsidian-minio.sh`,
`scripts/provision-ea-minio.sh`, make targets `obsidian-minio` / `ea-minio`.

`.env.example` / `scripts/check-env.sh`:

- Removed: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`,
  `OBSIDIAN_MINIO_SECRET_KEY`, `EA_MINIO_SECRET_KEY`.
- Added, on the change-me/empty check: `S3_ADMIN_ACCESS_KEY`,
  `S3_ADMIN_SECRET_KEY`, `S3_STS_SIGNING_KEY` (recipe
  `openssl rand -base64 32`), `JARVIS_S3_SECRET_KEY`,
  `OBSIDIAN_S3_SECRET_KEY`, `EA_S3_SECRET_KEY`, `DARKANGEL_S3_SECRET_KEY`.
- Added, **not** on the change-me/empty check (empty until copied from
  Keycloak after the first deploy): `S3_ADMIN_OIDC_CLIENT_SECRET`.

### 4. Metrics and dashboards

- `monitoring/prometheus/prometheus.yml`: jobs `minio` and `minio-bucket`
  are replaced by one job `seaweedfs` → `s3:9324` (default `/metrics`).
  `weed server -metricsPort` serves every component on that port.
- First dashboard step is empirical: `curl http://s3:9324/metrics` against
  the pinned version and map each panel to a metric that exists there.
  Target mapping:

| Panel today | Replacement |
|---|---|
| Cluster capacity used / total (`infra-overview`) | volume-server disk size / usage gauges |
| S3 requests, auth-rejected rate (`infra-overview`) | S3 request counter by `code` (403 = rejected auth) |
| Traffic in / out (`infra-overview`) | S3 bucket traffic counters, summed |
| Per-bucket requests / 4xx / 5xx / by API (`jarvis`, `darkangel`) | S3 request counter filtered on `bucket`, split by `code` / `type` |
| Per-bucket traffic (`jarvis`) | S3 bucket traffic counters by `bucket` |
| Per-bucket size and object count (`jarvis`, `darkangel`) | a gauge if the pinned version exports one; otherwise the panel is **deleted** |

- Panels with no metric are deleted, not approximated. If per-bucket size is
  missed later, the upgrade path is a small job exporting
  `weed shell s3.bucket.list` output; not built now.
- Logs need no change: Alloy already collects every container's logs via
  the Docker socket.

### 5. Keycloak (`infra` realm)

**`keycloak/realm-import/infra-realm.json`** — new realm `infra`. No client
secrets and no `users` array in git, per `keycloak/CLAUDE.md`.

- Groups: `s3-admin`, `s3-readwrite`, `s3-readonly`.
- Client **`s3-admin`** (admin UI): confidential, standard flow only, one
  exact redirect URI
  `https://s3-admin.infra.famillelallier.net/login/oidc/callback` (no
  trailing `*`), `post.logout.redirect.uris` the bare origin. Mappers: group
  membership → claim `groups`, full group path **off**, in ID and access
  token; audience `s3-admin`.
- Client **`s3-sts`** (humans getting S3 credentials): public, device
  authorization grant only (a CLI has no redirect origin to register).
  Mappers: the same `groups` mapper; audience `s3-sts`.

**`seaweedfs/iam.json.tmpl`** — committed, rendered by the `s3` entrypoint
(section 1). Contents:

- `sts`: `tokenDuration` `1h`, `maxSessionLength` `12h`, issuer
  `seaweedfs-sts`, `signingKey` `__S3_STS_SIGNING_KEY__`.
- One provider `keycloak`, type `oidc`: issuer
  `https://keycloak.famillelallier.net/realms/infra`, `clientId` `s3-sts`
  (the expected audience), `jwksUri`
  `http://keycloak:8080/realms/infra/protocol/openid-connect/certs`, no
  client secret (public client).
- `roleMapping` on claim `groups`: `s3-admin` → `S3AdminRole`,
  `s3-readwrite` → `S3WriteRole`, `s3-readonly` → `S3ReadOnlyRole`.
  **No `defaultRole`**: a realm user in no group gets no credentials.
- Policies, all on every bucket (`arn:aws:s3:::*` and `arn:aws:s3:::*/*`):
  `S3AdminPolicy` `s3:*`; `S3WritePolicy` get/put/delete/list;
  `S3ReadOnlyPolicy` get/list.
- Each role's trust policy allows `sts:AssumeRoleWithWebIdentity` only when
  `oidc:iss` equals the `infra` realm issuer.

Human flow, documented in `README.md` (no helper script until it's used
often): device login against the `infra` realm with `client_id=s3-sts` →
`aws sts assume-role-with-web-identity --endpoint-url
https://s3.infra.famillelallier.net --role-arn arn:aws:iam::role/<Role>
--web-identity-token <token>` → export the returned temporary keys.

### 6. Documentation

Same PR: `CLAUDE.md` (architecture entry, Obsidian paragraph, hostname
list, single-ingress lists), `keycloak/CLAUDE.md` (the `infra` realm), `README.md` (console section, Obsidian vault
section, `.env` key list, file tree), `AGENTS.md`, `.env.example`, the
`minio/dns` mention in `docker-compose.portainer.yml`'s comment,
`scripts/check-docker.sh` and `scripts/migrate-volumes.sh` comments.
Historical `docs/superpowers/*` files are left untouched.

## Cutover

S3-backed features in each app are down from step 1 until that app's step 5.

1. Merge the Infra PR, `git pull --ff-only`, add the new `.env` keys,
   `make up` (Keycloak imports the new `infra` realm on this boot).
   Then in the Keycloak console: copy the `s3-admin` client secret into
   `S3_ADMIN_OIDC_CLIENT_SECRET`, create your user in the `infra` realm with
   a verified email, add it to `s3-admin`, and `make up` again.
2. Orphans (manual, destructive, confirm first): `docker rm -f` the old
   minio container; `docker volume rm infra_minio-data`.
3. The four `make s3-provision` runs (section 3).
4. `./scripts/gen-certs.sh --force` (keeps the local CA, drops the minio
   SANs; reload NGINX); delete the two minio zones in Technitium.
5. Consumers, one PR each in their own repo:
   - **Jarvis**: endpoint `http://s3:8333`, access key `jarvis`,
     `MINIO_*` env keys renamed `S3_*`; drop the `.env.example` note about
     reusing MinIO root credentials.
   - **EA**: `EA_S3_ENDPOINT` default `s3:8333`, access key `ea`; update
     comments naming MinIO / `ea-api`.
   - **DarkAngel**: endpoint `http://s3:8333`, access key `darkangel`;
     delete its `make minio` target (Infra's `s3-provision` owns this now).
   - **Obsidian** (Remotely Save settings, no repo): endpoint
     `http://s3:8333` inside the container, `https://s3.infra.famillelallier.net`
     on other devices, access key `obsidian`; let it re-push the vault.

## Acceptance

- Unsigned `ListBuckets` against `http://s3:8333` returns 403 (auth on from
  first boot).
- Each app identity can put/get/list in its bucket and gets `AccessDenied`
  on another app's bucket.
- After re-running `make s3-provision` with a new secret, the old secret is
  rejected.
- `obsidian` bucket versioning reports `Enabled`.
- A >1 GB upload through `https://s3.infra.famillelallier.net` succeeds.
- `https://s3-admin.infra.famillelallier.net` redirects to Keycloak; an
  `s3-admin` member lands as admin, an `s3-readonly` member as readonly, and
  an `infra` user in no group is refused. No host path reaches `:8888`,
  `:9333` or `:9324`.
- STS: an `s3-readonly` session can get/list but gets `AccessDenied` on put;
  an `s3-readwrite` session can put; a user in no group gets no credentials;
  a token from another realm (e.g. `ea`) is rejected.
- With the IAM config loaded, the per-app static keys still behave as above
  (own bucket allowed, other buckets denied).
- Prometheus target `seaweedfs` is up; every remaining dashboard panel shows
  data.
- `git grep -i minio` matches only `docs/superpowers/*`.

## Out of scope

Data migration; filer mounts, tiering, S3 Tables; oauth2-proxy (native OIDC
is used instead); per-bucket STS roles; an STS login helper script; moving
apps from static keys to STS; a per-bucket size exporter; the EA /
DarkAngel test MinIOs.
