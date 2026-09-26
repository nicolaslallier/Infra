# Replace MinIO with SeaweedFS

Status: draft 2026-09-26

## Goal

Swap the shared object store from MinIO to SeaweedFS, like for like: a
maintained S3 server that consumers talk to exactly as before. MinIO is a
dead end here — no new images (the service is pinned to
`RELEASE.2025-09-07T16-13-09Z` on quay.io), and the community console lost
its admin features. No SeaweedFS-only feature (filer mounts, tiering,
S3 Tables) is in scope.

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
- EA and DarkAngel each run a throwaway MinIO in their own repos for
  integration tests. Those never touch Infra and stay as they are.

## Design

### 1. Services (`docker-compose.yml`)

`minio` and the `minio-data` volume are deleted. Added:

```yaml
s3:
  image: chrislusf/seaweedfs:<version>@sha256:<digest>
  restart: unless-stopped
  command: ["server", "-dir=/data", "-s3", "-metricsPort=9324"]
  environment:
    AWS_ACCESS_KEY_ID: ${S3_ADMIN_ACCESS_KEY:?Set S3_ADMIN_ACCESS_KEY in .env}
    AWS_SECRET_ACCESS_KEY: ${S3_ADMIN_SECRET_KEY:?Set S3_ADMIN_SECRET_KEY in .env}
  volumes:
    - s3-data:/data
  networks: [infra-net]
  healthcheck: # HTTP probe of the S3 listener on :8333

s3-admin:
  image: <same pin>
  restart: unless-stopped
  command: ["admin", "-masters=s3:9333", "-adminUser=admin",
            "-adminPassword=${S3_ADMIN_UI_PASSWORD:?Set S3_ADMIN_UI_PASSWORD in .env}"]
  networks: [infra-net]
  depends_on: [s3]
```

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
- The admin UI is protected only by its own `admin` / `S3_ADMIN_UI_PASSWORD`
  login — the same model as the MinIO console today. No oauth2-proxy.

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
- Added (all on the change-me/empty check): `S3_ADMIN_ACCESS_KEY`,
  `S3_ADMIN_SECRET_KEY`, `S3_ADMIN_UI_PASSWORD`, `JARVIS_S3_SECRET_KEY`,
  `OBSIDIAN_S3_SECRET_KEY`, `EA_S3_SECRET_KEY`, `DARKANGEL_S3_SECRET_KEY`.

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

### 5. Documentation

Same PR: `CLAUDE.md` (architecture entry, Obsidian paragraph, hostname
list, single-ingress lists), `README.md` (console section, Obsidian vault
section, `.env` key list, file tree), `AGENTS.md`, `.env.example`, the
`minio/dns` mention in `docker-compose.portainer.yml`'s comment,
`scripts/check-docker.sh` and `scripts/migrate-volumes.sh` comments.
Historical `docs/superpowers/*` files are left untouched.

## Cutover

S3-backed features in each app are down from step 1 until that app's step 5.

1. Merge the Infra PR, `git pull --ff-only`, add the new `.env` keys,
   `make up`.
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
- `https://s3-admin.infra.famillelallier.net` login works; no host path
  reaches `:8888`, `:9333` or `:9324`.
- Prometheus target `seaweedfs` is up; every remaining dashboard panel shows
  data.
- `git grep -i minio` matches only `docs/superpowers/*`.

## Out of scope

Data migration; filer mounts, tiering, S3 Tables; oauth2-proxy on the admin
UI; a per-bucket size exporter; the EA / DarkAngel test MinIOs.
