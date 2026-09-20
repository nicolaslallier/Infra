# Security review: hosting financial and medical data on `Infra`

**Date:** 2026-09-20 · **Scope:** this repository at `0d3199f` — Compose, NGINX,
scripts, Keycloak realms, OpenBao, monitoring, CI. Sibling app repos (Jarvis, EA,
LibreChat, the nurse app) were not read; where they matter it is said so.

---

## Verdict

Do not put regulated financial or medical data on this stack as it stands.

This is not a reflection on the quality of the code. The repo is unusually
well-reasoned — the drift guard, `check-env.sh`, the idempotent provisioning, the
"keep the token out of argv" discipline in the vault scripts are all better than
what most production shops ship. The problem is that it is a **homelab**, and
almost every deliberate homelab convenience in it is a finding once regulated data
is in scope:

- one flat network shared by a browser-streamed desktop, an LLM gateway and the
  database;
- three separate paths to root on the Docker daemon, one of which is "merge a PR
  on a public GitHub repo";
- no backups, no database audit trail, no encryption at rest, no MFA anywhere.

The gap is structural, not a list of hardening tweaks. Sections 1–3 are the
structural facts. Section 4 is the concrete code findings. Section 5 is the
recommendation, which is cheaper than it looks.

---

## 1. One flat trust domain

Every container is on a single external bridge, `infra-net`, with no
segmentation, no internal firewalling, and no mutual authentication between
services. Anything that lands on that network can open a TCP connection to
`postgres:5432`, `openbao:8200`, `minio:9000`, `neo4j:7687` and `loki:3100`.

What else is on that network today:

| Service | Why it is a problem next to a PHI database |
|---|---|
| `obsidian` | A full Linux desktop session streamed to a browser, running arbitrary Obsidian community plugins, with outbound internet. Plugin supply chain = code execution on `infra-net`. |
| LibreChat (`librechat`, `librechat-admin`) | An LLM gateway that makes outbound calls to third-party model APIs. Any PHI reaching it leaves your control, and no processor agreement covers it. |
| `airflow-scheduler` | Holds `/var/run/docker.sock` **read-write**. Any DAG is root on the daemon. |
| `ea-api`, `jarvis-api`, `nurse` app | Separate repos, separate review status, same network. |
| CI's throwaway `docker:28.5.2-cli` container | Joins the daemon, not the network — but see §2. |

Compounding it: `postgres` does `env_file: .env`, and `.env` is the **entire**
secret set for the stack — MinIO root, Grafana admin, Keycloak admin, RabbitMQ,
Neo4j, the Airflow Fernet key, the DNS admin password, every per-app DB password.
`docker exec` into `postgres`, or a superuser `COPY … FROM PROGRAM`, or reading
`/proc/1/environ`, hands over everything at once. The comment in `.env.example`
correctly identifies why `PORTAINER_API_KEY` must stay out of `.env`; the same
argument applies to the other forty values, which are all in there.

There is also no encryption in transit anywhere inside the stack. Every hop is
plaintext, and two of them say so explicitly:

- `postgres-exporter`: `…?sslmode=disable`
- `grafana`: `GF_DATABASE_SSL_MODE: disable`
- Keycloak → Postgres: no `KC_DB_URL_PROPERTIES`, so no TLS
- `openbao/config.hcl`: `tls_disable = true`
- MinIO S3 API: `http://minio:9000`
- AMQP, Bolt, Loki push, OTLP: all plaintext
- Postgres server-side TLS is not configured at all, so the NGINX
  `127.0.0.1:5432` passthrough is a cleartext channel too

On a single host this is defensible in a threat model where the bridge is
trusted. It is not defensible in one where `obsidian` runs third-party plugin
code on the same bridge, and it is not defensible to an auditor under
HIPAA §164.312(e)(1) or PCI-DSS Req. 4.

## 2. Root on the Docker daemon is reachable three ways

The Docker socket is the whole game. It reads every volume, every environment,
every byte at rest, and it bypasses every application-level control in this repo.
Three independent paths lead to it:

1. **Portainer.** `docker-compose.portainer.yml` mounts the socket read-write
   (correctly — that is its job) and publishes **9443, 9000 and 8000** on
   `${LAN_IP}`. Port 9000 is plain HTTP. The only gate is Portainer's own local
   admin account: no SSO, no MFA, no IP allowlist, no lockout. Anyone on the LAN
   with that one password owns the host. `nginx/conf.d/portainer.conf` adds a
   second, equally ungated route.
2. **Airflow.** `airflow-scheduler` mounts the socket read-write so
   `infra_pr_validation.py` can run sibling containers. `airflow.infra…` is behind
   Airflow's FAB login and nothing else — `AIRFLOW_ADMIN_PASSWORD` from `.env`,
   no MFA, no rate limit, no oauth2-proxy. CLAUDE.md already names this trade
   honestly; with PHI on the host it stops being a trade and becomes a defect.
3. **CI.** `docker-compose.runner.yml` mounts the socket into a self-hosted
   GitHub runner for a **public** repository. The workflow correctly avoids
   `pull_request`, and the security note in CLAUDE.md is the right analysis —
   but the conclusion stands: *merging to main executes code as root on the
   machine holding the data.* Branch protection is the only control, and branch
   protection is not a technical safeguard under any of the relevant regimes.
   `RepositoryAuthentication: false` in `portainer-stack.sh` means Portainer also
   fetches the compose file from public GitHub at deploy time.

Two more escape-surface items on the same host: `cadvisor` runs
`privileged: true` with `/` and `/var/lib/docker` mounted, and `node-exporter`
runs with `pid: host` and `/:/host`. Both are normal for a monitoring stack and
both are additional ways out of a container into the host that holds the data.

## 3. No evidence, no recovery

Three absences, each of which is a named requirement rather than a nice-to-have.

**No backups.** There is no `pg_dump`, no volume snapshot, no restore procedure
and no restore test anywhere in the repo — `grep -riE 'backup|pg_dump|snapshot'`
returns only prose about the OpenBao seal key. `make clean CONFIRM=1` deletes the
volumes and nothing anywhere can bring them back. Single host, single disk, no
replication, on a Mac that sleeps. This fails HIPAA §164.308(a)(7) (contingency
plan: data backup, disaster recovery, emergency mode) outright, and it is the
finding most likely to actually hurt you regardless of any regulator.

**No database audit trail.** Postgres runs with stock logging: no `pgaudit`, no
`log_connections`/`log_disconnections`, no `log_statement`. Nothing records who
read which patient row or which transaction. pgAdmin connects as a superuser
through a session that is attributable to a browser login, not to a person. This
is HIPAA §164.312(b) (audit controls) and §164.308(a)(1)(ii)(D) (information
system activity review), and it is also what makes a breach investigation
possible at all.

**Logs are neither protected nor governed.** `monitoring/loki/config.yml` sets
`auth_enabled: false` and configures no retention and no compactor. Alloy ships
the stdout of **every container on the host, across every Compose project**, into
it. So: any container on `infra-net` can read every other service's logs
unauthenticated; application logs containing patient or account identifiers land
there; NGINX's `main` log format records the full request line, so anything in a
query string is captured; and there is no retention window and no deletion path —
which collides with Law 25 / PIPEDA rights of erasure as squarely as it collides
with a 6-year audit-retention expectation.

OpenBao's audit device writes to stdout precisely so that Alloy picks it up, so
the vault's own audit trail inherits all of the above, including "any container
can read it".

## 4. Concrete findings in the code

Ordered by severity. Everything below is a specific line you can change.

### High

- **`nginx/conf.d/jarvis.conf` — `/api/` is unauthenticated, deliberately.** The
  `auth_request` block that would gate it is commented out and the file documents
  it as a `KNOWN GAP`: "anyone who can reach this vhost can call `/api/*`
  unauthenticated." If Jarvis ingests or serves documents, that is an open
  document API on the LAN. Uncomment the block.
- **The local CA private key is inside the NGINX container.**
  `gen-certs.sh` writes `certs/infra-ca.key` into `certs/`, and
  `docker-compose.yml` mounts the whole directory: `./certs:/etc/nginx/certs:ro`.
  NGINX needs `infra.crt` and `infra.key` only. Because that CA is trusted in
  your devices' keychains, a compromise of the most internet-adjacent container
  in the stack yields the ability to mint trusted certificates for any
  `*.famillelallier.net` name. Move the CA key out of `certs/` (or mount the two
  leaf files individually).
- **Admin planes have no MFA, no lockout and no password policy.** pgAdmin,
  Grafana, Airflow, Portainer, RabbitMQ management and the OpenBao UI each carry
  their own local credential from `.env`, outside Keycloak entirely. pgAdmin is
  effectively a PHI query console reachable from any LAN browser with one
  password. HIPAA §164.308(a)(4) / §164.312(d); Law 25 art. 3.
- **All three Keycloak realms are unhardened.** In `ea-realm.json`,
  `jarvis-realm.json` and `nurse-realm.json`: `passwordPolicy` unset (a
  one-character password is accepted), `bruteForceProtected` unset, no required
  MFA action, no session lifetimes, and `sslRequired: "external"` — which exempts
  private-network clients from HTTPS, i.e. every client you have.
- **`nurse-realm.json` is the medical app and is the weakest of the three.**
  `nurse-frontend` and `examiner-frontend` are **public** clients whose redirect
  URIs are `http://localhost:5173/*` — plaintext scheme plus a path wildcard.
  Seeded `nurse.demo` / `examiner.demo` accounts take their passwords from `.env`
  via `keycloak-seed-users.sh`. Demo accounts must not exist in a realm that
  will front real patient data.
- **`check-env.sh` validates presence, not strength.** It is excellent at
  catching an unset or `change-me` value and at the base64url cookie-key trap. It
  will pass `POSTGRES_PASSWORD=abc` without comment.

### Medium

- **No security headers and no `server_tokens off;`.** `nginx/nginx.conf` and
  `snippets/ssl.conf` set no HSTS, CSP, `X-Frame-Options`,
  `X-Content-Type-Options` or `Referrer-Policy`. Every vhost inherits that.
- **TLS policy is loose.** `ssl_ciphers HIGH:!aNULL:!MD5` permits non-PFS and CBC
  suites on TLS 1.2. Pin an ECDHE+AEAD list, or drop to TLS 1.3 only.
- **Credentials passed in container argv.** `keycloak-seed-users.sh` calls
  `kcadm.sh … --password "$KEYCLOAK_ADMIN_PASSWORD"`, and
  `provision-obsidian-minio.sh` / `provision-ea-minio.sh` call
  `mc admin user add local <user> "$SECRET"`. Both are visible in that
  container's process list and to `docker top`. The vault scripts and the Neo4j
  healthcheck already show the right pattern (stdin / environment, never argv) —
  it just was not applied here.
- **Floating image tags on a data host.** `technitium/dns-server:latest`,
  `lscr.io/linuxserver/obsidian:latest`, `portainer-ce:lts`,
  `myoung34/github-runner:ubuntu-noble`. `neo4j` is pinned by digest and is the
  model to follow. There is no image scanning, no signature verification and no
  SBOM anywhere in the pipeline.
- **The vault is storage, not a control.** `openbao` holds one credential — the
  root token — in `.openbao.env` on the same disk, never rotated, with no auth
  method, no policies, no per-app tokens and no TTLs. The `static` seal key sits
  beside the data it protects, so whoever has the disk has the vault (CLAUDE.md
  states this plainly). No application reads from it; everything still gets its
  secrets from `.env`. As a `.env` round-trip it works well; as a compliance
  control it currently counts for nothing.
- **`portainer-stack.sh` uses `curl -sSk`** — TLS verification disabled against
  the Portainer API. Container-to-container on a trusted bridge, so low, but the
  bridge's trustworthiness is exactly what §1 questions.
- **Secrets have no rotation story.** MinIO root, RabbitMQ, Neo4j, pgAdmin and
  the Keycloak bootstrap admin are all documented as *first-boot-only* — changing
  the `.env` value does not rotate the live credential. There is no procedure for
  rotating any of them, and no expiry on anything.

### Low

- `MINIO_PROMETHEUS_AUTH_TYPE: public` and OpenBao's
  `unauthenticated_metrics_access` expose metrics to anything on `infra-net`.
  Consistent with §1; both become non-issues once the network is segmented.
- `OAUTH2_PROXY_EMAIL_DOMAINS: "*"` on both proxies — realm membership is the
  only authorization check. No role gating (`ALLOWED_ROLES` is available).
- `OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION: "true"` on both proxies.
  The reason given is accurate (Keycloak hostname-v2 vs. the internal issuer URL),
  and the fix is to use the external issuer URL with the existing
  `keycloak.famillelallier.net` network alias rather than to keep the check off.
- RSA-2048 leaf certificates, 825 days, unencrypted keys, no rotation automation.
- `nginx/conf.d/rabbitmq.conf` has `auth_basic` present but commented out.

---

## 5. What to actually do

### The recommendation: do not retrofit this stack — stand a second one beside it

Hardening `Infra` into a regulated-data environment means removing Portainer,
removing the socket from Airflow, removing the public-repo CI path, segmenting the
network, moving Obsidian and LibreChat off it, and adding backups, audit and MFA.
At that point you have not hardened this stack; you have replaced it, and you have
also lost every convenience that made it pleasant to run.

The cheaper path is scope separation:

1. **A separate host** (or at minimum a separate Docker daemon, ideally a separate
   physical machine or a dedicated VM) for regulated data. Its own network, its
   own `.env`, no shared socket, no Portainer, no GitHub-runner deploy, deployed
   by `docker compose up -d` over SSH by a human.
2. **Four services, not twenty**: the app, Postgres, Keycloak, NGINX. Every
   service you add is a service you must justify to an auditor and patch forever.
3. **Keep `Infra` exactly as it is** for everything else. It is good at what it
   does. The nurse app moves out; Obsidian, LibreChat, Airflow, Portainer and the
   CI runner stay here and never touch the regulated host.
4. **Reuse the good parts of this repo** on the new stack: `check-env.sh`, the
   idempotent per-app provisioning, the drift guard, the `${INFRA_DIR}` pattern,
   the `resolver` + `set $upstream` idiom. That machinery is the valuable output
   of this repo and it transfers unchanged.

Connect the two only where you must, one direction, one port, explicitly — not by
putting both on `infra-net`.

### Reduce what is in scope before you protect it

The single highest-leverage move, and the laziest:

- **Never store card numbers.** Use a processor (Stripe, Moneris) with
  hosted/tokenized entry so PANs never reach your host. That is the difference
  between PCI-DSS SAQ-A (a questionnaire) and SAQ-D (hundreds of controls).
- **Store the minimum PHI.** A patient reference plus the specific fields the app
  needs beats a copy of the chart. Data you do not hold cannot leak and does not
  need encrypting, logging, backing up or deleting on request.
- **Keep PHI out of logs, traces and LLM prompts.** The nginx `main` log format,
  the OTel spans going to Tempo, and any LibreChat path are all exfiltration
  routes that look like telemetry. Decide this before the app is written; it is
  very expensive afterwards.

### If it must run on this stack anyway — ordered minimum

**P0 — do before any regulated byte lands**

1. Backups: nightly `pg_dump` + MinIO mirror + the OpenBao seal key, encrypted,
   off this machine, **with a restore actually tested**. One cron container.
2. Full-disk encryption on the host, verified (FileVault on the Mac and on
   `/Volumes/Docker`, which is where the Docker disk image lives).
3. Take `/var/run/docker.sock` off `airflow-scheduler`; delete or relocate the
   PR-validation DAG. Remove the self-hosted-runner deploy path, or move the
   regulated workload off any host the runner can reach.
4. Bind Portainer to `127.0.0.1` only and reach it over SSH port-forward; drop
   the `:9000` plain-HTTP publish and the `portainer.infra…` vhost.
5. Uncomment the `auth_request` block on `jarvis.conf`'s `/api/`; put every admin
   UI (pgAdmin, Grafana, Airflow, RabbitMQ, OpenBao) behind oauth2-proxy the way
   Obsidian already is.
6. Keycloak realms: `passwordPolicy` (length 12+, notUsername, passwordHistory),
   `bruteForceProtected: true`, **required TOTP**, `sslRequired: "all"`, sane
   session lifetimes. Delete the `nurse.demo` / `examiner.demo` accounts and the
   `localhost` wildcard redirect URIs.
7. Move `certs/infra-ca.key` out of the directory mounted into NGINX.

**P1 — within the first month**

8. `pgaudit` + `log_connections` / `log_disconnections`, shipped somewhere
   append-only and off-host; Loki `auth_enabled` on, with a retention policy and
   a documented deletion path.
9. TLS inside the stack: Postgres server certs and `sslmode=verify-full` on every
   DSN; MinIO over HTTPS; OpenBao with `tls_disable = false`.
10. Split `.env` so that `postgres` receives only the variables it needs —
    `env_file: .env` on that service is the widest single credential exposure in
    the repo.
11. Security headers, HSTS, `server_tokens off`, a modern cipher list.
12. Pin every image by digest; add a scanner (Trivy) to CI; stop pulling compose
    from a public repo at deploy time.
13. Real vault use: Keycloak OIDC auth on OpenBao, per-app policies and tokens,
    revoke the root token, applications read secrets at runtime instead of via
    Compose interpolation.

**P2 — before you would survive an audit**

14. Written risk analysis, security policies, incident-response and
    breach-notification runbooks, workforce training records. These are documents,
    not code, and under both HIPAA and Law 25 their absence is itself the
    violation.
15. Named privacy officer (Law 25 art. 3.1 — in Quebec this defaults to the
    highest-ranking person unless designated in writing) and a privacy impact
    assessment for the project.
16. Processor agreements: a BAA with anyone touching PHI (that includes any LLM
    API — most consumer tiers explicitly exclude PHI), and equivalent contracts
    under Law 25 for any transfer outside Quebec.
17. Access reviews, joiner/mover/leaver process, and an annual restore drill.

---

## Things this review did not cover

- The application repos (Jarvis, EA, nurse, LibreChat) — the most likely place
  for injection, authorization and data-handling bugs, and the place PHI is
  actually processed. They need their own review.
- Host OS posture (macOS hardening, patch level, FileVault state, physical
  security of the machine).
- The LAN itself: Wi-Fi, router, guest-network isolation, who else is on it.
  Everything in this stack trusts the LAN, so the LAN is part of the boundary.
