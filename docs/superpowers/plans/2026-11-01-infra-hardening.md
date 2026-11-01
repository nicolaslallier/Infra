# Infra Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the twelve gaps found in the 2026-11-01 review: tested backups, alerting to ntfy, bounded log/metric retention, pinned images with automated bumps, healthchecks and a post-deploy health gate, memory limits, a working deploy runner, root-owned host files after CI, `.env` placeholders, Postgres connection logging, and a first real OpenBao consumer.

**Architecture:** Everything rides machinery the stack already has. Backups are a new Prefect flow in `prefect-flows` (which already holds the Docker socket) that writes into a new external volume `infra-backups`; Heaven snapshots that volume; the flow publishes `infra_backup_last_success_timestamp_seconds` through node-exporter's textfile collector. Alerting is Grafana-provisioned rules with a webhook contact point to ntfy. The OpenBao snapshot uses a narrowly scoped periodic token, which makes the backup flow the vault's first consumer (item 12).

**Tech Stack:** Docker Compose (Portainer Git stack), Grafana 12 alerting provisioning, Prometheus 3.5, Loki 3.5, Prefect 3.8.7 (`docker`, `boto3` already installed), OpenBao 2.6.2, ntfy 2.29, Renovate.

**Spec:** No separate spec file. The source is the twelve-item proposal from the 2026-11-01 session, restated under "Spec (restated)" below.

## Spec (restated)

| # | Item | Task |
|---|------|------|
| 1 | Backups, restored at least once: postgres, openbao (+ seal key kept elsewhere), neo4j, ntfy | 10, 11, 12, 13 |
| 2 | Alerting via ntfy: target down, disk < 15 %, restart loop, OOM, backup > 26 h old | 3 (+ rule in 11) |
| 3 | Loki retention + compactor | 1 |
| 4 | Pin floating tags by digest, Renovate, oauth2-proxy upgrade | 6, 7 |
| 5 | Healthchecks on key services + deploy waits for healthy | 8 |
| 6 | Memory limits on the heavy services | 9 |
| 7 | Restore the deploy runner | 4 |
| 8 | Stop CI leaving root-owned files in the host checkout | 2 |
| 9 | `.env` hygiene: Jarvis client secret, `SMTP_MYNETWORKS`, SMTP relay password | 5 |
| 10 | Prometheus retention 15 d → 90 d with a size cap | 1 |
| 11 | Postgres `log_connections` / `log_disconnections` | 1 |
| 12 | First OpenBao consumer | 12 |

**Skipped on purpose:** an alert for an offline GitHub runner (there's no metric for it; `make runner-status` stays the check), Alertmanager, long-term metric storage, Postgres HA.

## Global Constraints

- The deploy host is the **Windows laptop 192.168.2.10** (Docker Desktop, WSL checkout `/mnt/c/Users/nicol/OpenCode/Infra`), not the Mac. See memory `deploy-host-ssh-access`. Every live verification step runs there.
- Every merge to `main` that touches non-doc files redeploys the whole stack (force-recreate, brief DNS drop). Group tasks into the PRs listed under "PR grouping"; don't merge one PR per step.
- No new `ports:` entry on any backend service (CLAUDE.md "Single-ingress rule").
- No secret on any command line or in a healthcheck `test:` (it would show in `docker inspect` and process lists).
- New `.env` keys go in `.env.example` too (check-env diffs the two), then `make vault-seed` so the vault keeps the record.
- New bind mounts use `${INFRA_DIR:-.}/...`; new shared volumes are `external: true` and created by `scripts/portainer-volumes.sh` (default list), like `darkangel-web`.
- Image pins use the **multi-arch index digest** (`docker buildx imagetools inspect <ref>` → top-level `Digest`), never a single-platform digest: the laptop is amd64, the Macs are arm64.
- Prefect flow settings use their own prefix (`BACKUP_*`), never `PREFECT_*`.
- Flow tests are plain-assert files run with `uv run --no-project --python 3.12 --with prefect==3.8.7 python prefect/flows/test_<name>.py`.

## Open decisions (owner: user). Tasks that depend on one stop there.

- **D1. Where Heaven's repository lives.** Heaven's default repository is a named volume on the same disk as the data, so it isn't a backup. Pick a different physical disk, a NAS path, or an off-site target for `HEAVEN_REPOSITORY_PATH`. Blocks Task 13.
- **D2. Where the OpenBao seal key copy lives** (a password manager entry is fine). Blocks Task 13's final checkbox.

## PR grouping

| PR | Tasks | Deploy risk |
|----|-------|-------------|
| A `chore/retention-logging` | 1 | low, config only |
| B `fix/ci-deploy-ownership` | 2 | low |
| C `feat/alerting` | 3 | low |
| — ops, no PR | 4, 5 | none |
| D `chore/pin-images` | 6, 7 | medium (oauth2-proxy major-ish bump) |
| E `feat/healthchecks` | 8 | medium (a wrong probe marks a service unhealthy) |
| F `chore/mem-limits` | 9 | medium (a limit set too low means OOM kills) |
| G `feat/backups` | 10, 11, 12 | medium |
| — Heaven repo PR + runbook | 13 | none here |

## Review Focus

1. **A backup that "succeeds" with an empty or truncated file.** `pg_dumpall` exiting non-zero mid-stream must leave no file under its final name and no fresh metric. Pinned by `test_failed_dump_leaves_no_file` (Task 11).
2. **Neo4j left stopped after a failed dump.** The dump stops the container; it must be restarted in a `finally`, whatever happens. Pinned by `test_neo4j_restarted_on_failure` (Task 11).
3. **Alerts that can never fire.** A rule whose query returns nothing (a wrong `job` label, `/rootfs` vs `/host` mountpoint) stays silently "Normal". Each rule in Task 3 is proven by forcing it to fire once.
4. **A healthcheck probe that's missing from the image** (no `wget`/`curl` in it) marks a healthy service unhealthy, and the Task 8 gate then fails every deploy. Each probe is run with `docker exec` before it's committed.
5. **The OpenBao backup token expiring.** A periodic token dies if it isn't renewed within its period. The flow renews it every run, and the backup-age alert (Task 11) catches the day it stops working.

---

### Task 1: Retention and Postgres connection logging (items 3, 10, 11)

**Files:**
- Modify: `monitoring/loki/config.yml`
- Modify: `docker-compose.yml` (prometheus `command:`, postgres `command:`)
- Modify: `CLAUDE.md` (one line each under LGTM and postgres)

**Interfaces:** Produces nothing other tasks consume.

- [ ] **Step 1: Loki retention.** Add a top-level `compactor:` block with `working_directory: /loki/compactor`, `retention_enabled: true`, `delete_request_store: filesystem` (Loki 3 refuses retention without it), and `compaction_interval: 10m`. Under `limits_config:` add `retention_period: 744h` (31 days).
- [ ] **Step 2: Validate Loki.**
  Run: `docker run --rm -v "$PWD/monitoring/loki/config.yml:/c.yml:ro" grafana/loki:3.5.3 -config.file=/c.yml -verify-config`
  Expected: exit 0, `config is valid`.
- [ ] **Step 3: Prometheus retention.** In the `prometheus` command, replace `--storage.tsdb.retention.time=15d` with `--storage.tsdb.retention.time=90d` and add `--storage.tsdb.retention.size=20GB`. Whichever limit is hit first applies.
- [ ] **Step 4: Postgres logging.** Add to `postgres` `command: ["postgres", "-c", "log_connections=on", "-c", "log_disconnections=on"]`. PG18 still accepts `on` for `log_connections` (it maps to `receipt,authentication,authorization`).
- [ ] **Step 5: Validate compose.** Run `make config >/dev/null`. Expected: exit 0.
- [ ] **Step 6: Commit, open PR A, merge, deploy.** Then verify on the host:
  - `docker compose exec postgres psql -U "$POSTGRES_USER" -c 'show log_connections'` → `on`.
  - `docker logs infra-postgres-1 2>&1 | grep -m1 'connection authorized'` → one line.
  - Loki logs show `compactor` started with no `retention` error.
  - `docker logs infra-prometheus-1 2>&1 | grep -m1 retention` → shows `90d` and `20GiB`.

```bash
git commit -am "chore(monitoring): bound Loki/Prometheus retention, log postgres connections"
```

### Task 2: CI deploy stops leaving root-owned files (item 8)

**Files:**
- Modify: `scripts/ci-deploy.sh` (the `sh -euc` body passed to `docker run`)
- Modify: `CLAUDE.md` "CI: deploying on a push to main" (one sentence)

Root cause: the deploy container runs as root against the host checkout. `git fetch`/`merge` and `vault-render` (`.env`, `.env.bak`) then write root-owned files that the `this` user can't read or update afterwards.

- [ ] **Step 1: Restore ownership on exit.** Near the top of the `sh -euc` body, add an `EXIT` trap: `owner=$(stat -c %u:%g .)` (owner of the checkout root), then `chown -R "$owner" .git` and `chown "$owner" .env .env.bak 2>/dev/null || true`. It's a trap so it also runs when the deploy fails.
- [ ] **Step 2: Fix the current state once on the host.** Run `sudo chown -R this: /mnt/c/Users/nicol/OpenCode/Infra/.git /mnt/c/Users/nicol/OpenCode/Infra/.env` in WSL. (On a `/mnt/c` drvfs mount, chown may be a no-op. If `stat` already shows the WSL user, skip this.)
- [ ] **Step 3: Verify.** After the next CI deploy (Task 4 must be done first), on the host: `find .git .env ! -user "$(id -u)" | wc -l` → `0`, and `git fetch` succeeds as the normal user.
- [ ] **Step 4: Commit, PR B.**

```bash
git commit -am "fix(ci-deploy): hand .git and .env back to the checkout owner after a deploy"
```

### Task 3: Alerting through ntfy (item 2)

**Files:**
- Create: `monitoring/grafana/provisioning/alerting/contact-points.yml`
- Create: `monitoring/grafana/provisioning/alerting/policies.yml`
- Create: `monitoring/grafana/provisioning/alerting/rules.yml`
- Modify: `docker-compose.yml` (grafana `environment:` gets `GRAFANA_NTFY_TOKEN: ${GRAFANA_NTFY_TOKEN:-}`)
- Modify: `.env.example` (`GRAFANA_NTFY_TOKEN=` with a comment naming the command that mints it)
- Modify: `scripts/check-env.sh` (warn, don't fail, when empty, like `SMTP_RELAY_*`)
- Modify: `CLAUDE.md` (LGTM bullet: where rules live, how to add one)

**Interfaces:**
- Produces: contact point `ntfy`, folder `Infra`, rule group `infra` (60 s evaluation). Task 9 adds an OOM rule and Task 11 adds a backup-age rule to this same `rules.yml` group.

- [ ] **Step 1: Mint the ntfy token.** Run `make ntfy-provision app=grafana topic=alerts`. This gives write access to `alerts-*`. Put the printed token in the vault (`make vault-cli` → `bao kv patch infra/env GRAFANA_NTFY_TOKEN=<tk_…>`). Subscribe the phone to topic `alerts-infra`.
- [ ] **Step 2: Contact point.** In `contact-points.yml`: `apiVersion: 1`, one contact point named `ntfy` with a `webhook` receiver:
  - url `http://ntfy/alerts-infra?tpl=yes&t={{.title}}&m={{.message}}` (ntfy fills the title and message from Grafana's JSON body)
  - `httpMethod: POST`
  - `authorization_scheme: Bearer`
  - `authorization_credentials: ${GRAFANA_NTFY_TOKEN}` (Grafana interpolates env vars in provisioning files)
- [ ] **Step 3: Policy.** In `policies.yml`: the root policy routes to receiver `ntfy`, `group_by: [alertname]`, `repeat_interval: 4h`.
- [ ] **Step 4: Rules.** Create the first rule in the Grafana UI, use **Export → YAML** to get the exact provisioning shape, and write all rules into `rules.yml` in that shape. Every rule's datasource is `uid: prometheus`. The rules:

  | title | PromQL (query A) | condition | for |
  |---|---|---|---|
  | Target down | `up == 0` | A > 0 | 5m |
  | Disk low | `node_filesystem_avail_bytes{job="node",mountpoint="/host"} / node_filesystem_size_bytes{job="node",mountpoint="/host"}` | A < 0.15 | 15m |
  | Container restart loop | `changes(container_start_time_seconds{name=~"infra-.+"}[15m])` | A > 2 | 0m |

  Before committing the Disk low rule, run its query in Explore. node-exporter runs with `--path.rootfs=/host`, so the root mountpoint may be reported as `/`. Use whichever label returns a series.
- [ ] **Step 5: Prove each rule fires.** After deploying:
  - Target down: `docker stop infra-nginx-exporter-1`, wait 5 minutes, a phone notification arrives, then `docker start` it and a resolved notification arrives.
  - Disk low: temporarily edit the threshold to `< 0.99` in the UI (provisioned rules aren't editable there, so use a scratch copy of the rule).
  - Restart loop: run `docker restart infra-nginx-exporter-1` three times.

  Expected: three notifications in `alerts-infra`.
- [ ] **Step 6: Commit, PR C.**

```bash
git commit -am "feat(monitoring): provisioned Grafana alert rules, delivered to ntfy"
```

### Task 4: Restore the deploy runner (item 7). Ops, no PR.

As of 2026-10-31 the runner container was crash-looping on a missing `Runner.Listener`, and post-merge deploys for #94/#95 were queued.

- [ ] **Step 1:** Run `make runner-status`. Note both sides (container, GitHub registration). If GitHub reports the PAT as refused, run `make runner-env FORCE=1 && make runner-restart` and go to Step 3.
- [ ] **Step 2:** Run `make runner-pull` (GitHub retires old runner versions; a stale image is the most likely cause of a missing listener). If it still crash-loops, use superpowers:systematic-debugging against `make runner-logs`. Don't patch the image.
- [ ] **Step 3: Verify.** `make runner-status` shows the container running *and* an online runner with label `infra`. Re-run the latest `deploy.yml` with `gh workflow run deploy.yml`, then `gh run watch` → success.

### Task 5: `.env` hygiene (item 9). Ops, no PR.

All edits go in the vault (`make vault-cli`, `bao kv patch infra/env …`). The next `make up` renders them.

- [ ] **Step 1:** `JARVIS_OAUTH_CLIENT_SECRET`: copy it from Keycloak (realm `jarvis`, the oauth2-proxy client → Credentials). See `keycloak/CLAUDE.md`.
- [ ] **Step 2:** `SMTP_MYNETWORKS=127.0.0.0/8,<subnet>`, where `<subnet>` comes from `docker network inspect infra-net -f '{{(index .IPAM.Config 0).Subnet}}'` on the host.
- [ ] **Step 3:** `SMTP_RELAY_PASSWORD`: a Workspace app password for `notifications@famillelallier.net`.
- [ ] **Step 4: Verify.** Run `make vault-render && make check-env`. Expected: no error and no warning about these three. Then send a test mail: `docker compose exec smtp sh -c 'printf "Subject: t\n\nok" | sendmail -f notifications@famillelallier.net <you>'` and confirm it arrives.

### Task 6: Pin every floating image and upgrade oauth2-proxy (item 4a)

**Files:**
- Modify: `docker-compose.yml` (image lines for `pgvector/pgvector:pg18`, `dpage/pgadmin4:9`, `nginx:alpine-otel`, `technitium/dns-server:latest`, `rabbitmq:4-management`, `lscr.io/linuxserver/obsidian:latest`, and the four `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`)
- Modify: `docker-compose.runner*.yml` / `docker-compose.portainer.yml` only if they reference a floating tag (`portainer-ce:lts` does: pin it)

- [ ] **Step 1: Resolve versions for `:latest`.** On the host, `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' infra-dns-1 infra-obsidian-1`. Use the version that's running now, so pinning changes nothing.
- [ ] **Step 2: Pin.** Each line becomes `image: <repo>:<tag>@sha256:<index digest>` (Global Constraints), with a one-line comment above it saying why, in the style of the neo4j line.
- [ ] **Step 3: oauth2-proxy.** Read the release notes from v7.6.0 to the latest v7.x and list any renamed or removed `OAUTH2_PROXY_*` setting used by any of the four services. Bump all four to the same tag and digest in one commit, with any renames applied.
- [ ] **Step 4: Validate.** Run `make config >/dev/null` (exit 0). Then on the host, `docker compose pull` for the changed services. Expected: each digest pulls.
- [ ] **Step 5 (after deploy): Verify.** Log in through each gate in a private window: `jarvis.famillelallier.net`, `obsidian.infra…`, `s3-admin.infra…`, `prefect.infra…`. Expected: Keycloak login, then the app. `dig @192.168.2.10 grafana.infra.famillelallier.net` returns `LAN_IP`.

### Task 7: Renovate keeps the pins current (item 4b)

**Files:**
- Create: `renovate.json`

- [ ] **Step 1:** `renovate.json`:
  - `extends: ["config:recommended", "docker:pinDigests"]`
  - `enabledManagers: ["docker-compose"]`
  - `schedule: ["before 6am on saturday"]`
  - `prConcurrentLimit: 3`
  - `automerge: false` (every merge deploys)
  - `ignoreDeps: ["infra-ollama-proxy"]` (built locally, `pull_policy: never`)
  - a `packageRules` entry that disables `major` updates for `pgvector/pgvector`, `neo4j`, `openbao/openbao` and `chrislusf/seaweedfs` (store-format upgrades are deliberate)
- [ ] **Step 2:** Validate with `npx --yes --package renovate -- renovate-config-validator renovate.json`. Expected: `Config validated successfully`.
- [ ] **Step 3: User action.** Install the Renovate GitHub App on `nicolaslallier/Infra`. Expected: an onboarding or dependency-dashboard issue appears.
- [ ] **Step 4: Commit with Task 6, PR D.**

```bash
git commit -am "chore(images): pin every image by digest, upgrade oauth2-proxy, add Renovate"
```

### Task 8: Healthchecks and a post-deploy health gate (item 5)

**Files:**
- Modify: `docker-compose.yml` (`healthcheck:` on the services below; `depends_on` of `nginx` and `grafana` switched to `service_healthy` where the dependency now has one)
- Create: `scripts/wait-healthy.sh`
- Modify: `Makefile` (`up` and `pull` call `./scripts/wait-healthy.sh` after the deploy)
- Modify: `CLAUDE.md` (one paragraph: what the gate checks, `WAIT_HEALTHY=0` to skip)

**Interfaces:**
- Produces: `scripts/wait-healthy.sh [timeout_seconds=300]`. Exit 0 when no `infra` container is `starting`, `unhealthy`, `restarting` or `exited`. Exit 1 after the timeout, listing the offenders with their last health log line. Containers are found with `docker ps -a --filter label=com.docker.compose.project=infra` (the same label approach `vault-env.sh` uses).

- [ ] **Step 1: Pick probes, then prove each binary exists.** Candidates:

  | service | test |
  |---|---|
  | nginx | `wget -q -O /dev/null http://127.0.0.1:8080/stub_status` |
  | grafana | `wget -q -O /dev/null http://127.0.0.1:3000/api/health` |
  | prometheus | `wget -q -O /dev/null http://127.0.0.1:9090/-/ready` |
  | loki | `wget -q -O /dev/null http://127.0.0.1:3100/ready` |
  | litellm | `python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:4000/health/liveliness')"` |
  | prefect-server | `python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:4200/api/health')"` (check whether `/api/health` is exempt from the auth string; if not, use the `/api/ready` route that is) |
  | oauth2-proxy* | `wget -q -O /dev/null http://127.0.0.1:4180/ping` |
  | dns | `dig`/`nslookup` if present, otherwise TCP-probe 5380 with `bash -c '</dev/tcp/127.0.0.1/5380'` |

  On the host, `docker exec <container> sh -c '<test>'; echo $?` for each one → `0`. If a binary is missing, use the next option in the row. Don't add a package.
- [ ] **Step 2: Add the healthchecks** with `interval: 15s`, `timeout: 5s`, `retries: 5`, `start_period` = observed boot time × 2 (Keycloak/litellm: 120s).
- [ ] **Step 3: Write `wait-healthy.sh`** to the interface above. Poll every 5 s.
- [ ] **Step 4: Prove the gate fails.** On the host, `docker compose exec loki kill 1`, then immediately `./scripts/wait-healthy.sh 30`. Expected: exit 1, `loki` listed. Then wait for it to recover and re-run. Expected: exit 0.
- [ ] **Step 5: Commit, PR E.** After the deploy, `make up` ends with the gate's `all healthy` line, and the CI deploy job turns red if it doesn't.

```bash
git commit -am "feat(compose): healthchecks on edge/monitoring services, deploy waits for healthy"
```

### Task 9: Memory limits (item 6)

**Files:**
- Modify: `docker-compose.yml` (`mem_limit:` on neo4j, keycloak, litellm, prometheus, obsidian, loki)
- Modify: `monitoring/grafana/provisioning/alerting/rules.yml` (OOM rule)

- [ ] **Step 1: Measure.** In Grafana Explore: `max_over_time(container_memory_working_set_bytes{name=~"infra-(neo4j|keycloak|litellm|prometheus|obsidian|loki)-1"}[14d])`. Also record the Docker Desktop VM total (`docker info --format '{{.MemTotal}}'` on the host).
- [ ] **Step 2: Set limits** at about 1.5× the 14-day peak, rounded up to 256 MiB. The sum of all six must stay under 60 % of the VM total, and the plan stops here if it doesn't. Neo4j's limit must be ≥ heap max (512M) + pagecache (256M) + 512M of headroom. Keycloak's JVM sizes itself from the container limit (`MaxRAMPercentage`), so it needs no flag.
- [ ] **Step 3: OOM rule.** Add to group `infra`: title `Container OOM-killed`, query `increase(container_oom_events_total{name=~"infra-.+"}[10m])`, condition `A > 0`, for `0m`.
- [ ] **Step 4: Verify after deploy.** `docker stats --no-stream` shows a `LIMIT` column equal to the configured values. After 48 h, the OOM rule has stayed `Normal`.
- [ ] **Step 5: Commit, PR F.**

```bash
git commit -am "chore(compose): memory limits on the six heaviest services, alert on OOM"
```

### Task 10: Backup volume and metric plumbing (item 1, part 1)

**Files:**
- Modify: `scripts/portainer-volumes.sh` (default list becomes `darkangel-web infra-backups`)
- Modify: `docker-compose.yml`:
  - top-level `volumes: infra-backups: {external: true}`
  - `prefect-flows` gets the mount `infra-backups:/backups` and env `BACKUP_DIR: /backups`, `BACKUP_PG_USER: ${POSTGRES_USER}`, `BACKUP_KEEP: "3"`
  - `node-exporter` gets the mount `infra-backups:/textfile:ro` and the flag `--collector.textfile.directory=/textfile/metrics`

**Interfaces:**
- Produces: the directory layout under `/backups`, which Tasks 11–13 use:
  - `/backups/<target>/<target>-<YYYYmmddTHHMMSSZ>.<ext>` for `target ∈ {postgres, neo4j, ntfy, openbao}`
  - `/backups/metrics/backup.prom`

- [ ] **Step 1:** Make the edits. `make app-volumes` creates the volume on the host. Expected: `docker volume inspect infra-backups` → exit 0.
- [ ] **Step 2:** Run `make config >/dev/null` → exit 0. Commit (the PR stays open until Task 12).

```bash
git commit -am "feat(backups): shared infra-backups volume, textfile collector on node-exporter"
```

### Task 11: The `backup` flow: postgres, neo4j, ntfy (item 1, part 2)

**Files:**
- Create: `prefect/flows/backup.py`
- Create: `prefect/flows/test_backup.py`
- Modify: `prefect/flows/serve.py` (add `backup.to_deployment(name="nightly", schedule=Cron("30 1 * * *", timezone="America/Toronto"), concurrency_limit=ONE_AT_A_TIME)`)
- Modify: `monitoring/grafana/provisioning/alerting/rules.yml` (backup-age rule)
- Modify: `CLAUDE.md` (a `#### backup` section under "Prefect: pipelines", in the style of the others)

**Interfaces:**
- Consumes: the layout from Task 10. The container is found by label `com.docker.compose.project=infra` + `com.docker.compose.service=<name>`.
- Produces, in `backup.py`:
  - `dump_name(target: str, ext: str, now: datetime) -> str`: `"<target>/<target>-<now UTC %Y%m%dT%H%M%SZ>.<ext>"`
  - `to_prune(names: list[str], keep: int) -> list[str]`: every name except the `keep` newest (the timestamp sorts lexically)
  - `metrics_text(last_success: dict[str, float]) -> str`: Prometheus text with `# HELP`/`# TYPE infra_backup_last_success_timestamp_seconds gauge` and one line per target
  - `write_atomic(path: Path, chunks: Iterable[bytes]) -> None`: writes `path.with_suffix(path.suffix + ".part")`, renames it on success, deletes the `.part` on any exception
  - tasks `dump_postgres() -> Path`, `dump_neo4j() -> Path`, `dump_ntfy() -> Path`
  - flow `backup() -> dict[str, str]`, whose `name="backup"`
  - `metrics/backup.prom` carries the previous success time for any target that failed this run (read back from the old file), so one failure doesn't reset the others' age

- [ ] **Step 1: Write the failing tests** in `test_backup.py` (plain asserts, `if __name__ == "__main__"` runner, like `test_serve.py`):
  - `test_dump_name`: `dump_name("postgres", "sql.gz", datetime(2026,11,1,6,30,tzinfo=UTC)) == "postgres/postgres-20261101T063000Z.sql.gz"`
  - `test_to_prune_keeps_newest`: from five names on consecutive days, `to_prune(names, 3)` returns the two oldest
  - `test_metrics_text`: `'infra_backup_last_success_timestamp_seconds{target="postgres"} 1700000000' in metrics_text({"postgres": 1700000000.0})`, and the text ends with `"\n"`
  - `test_failed_dump_leaves_no_file`: `write_atomic(tmp/"x.gz", gen_that_yields_then_raises())` raises, and afterwards neither `x.gz` nor `x.gz.part` exists
  - `test_neo4j_restarted_on_failure`: with a fake docker client whose `containers.run` raises, `dump_neo4j.fn()` raises and the fake container's `start` was called once (inject the client through a module-level `_docker()` factory that the test monkeypatches)
  - extend `test_serve.py`: the `backup` deployment exists and passes `test_one_run_at_a_time` unchanged
- [ ] **Step 2: Run the tests and confirm they fail.**
  Run: `uv run --no-project --python 3.12 --with prefect==3.8.7 --with docker python prefect/flows/test_backup.py`
  Expected: `ModuleNotFoundError: backup` / `AttributeError`.
- [ ] **Step 3: Implement `backup.py`** to the interface above:
  - `dump_postgres`: `exec_run(["pg_dumpall", "-U", BACKUP_PG_USER], user="postgres", stream=True, demux=False)`, gzip the chunks through `write_atomic`, then `exec_inspect` → a non-zero `ExitCode` raises (after the stream ends, so the `.part` is removed by `write_atomic`'s failure path; raise inside the generator).
  - `dump_neo4j`: stop the neo4j container, then `containers.run(<neo4j container's own image>, ["neo4j-admin", "database", "dump", "neo4j", "--to-path=/backups/neo4j/.tmp"], volumes={<neo4j-data volume name from the container's Mounts>: {"bind": "/data"}, "infra-backups": {"bind": "/backups"}}, remove=True)`, then rename to `dump_name(...)`. `start()` the container in `finally`. Nightly outage of about a minute; Neo4j Community has no online dump.
  - `dump_ntfy`: `containers.run("alpine:3", ["tar", "czf", "/backups/ntfy/.tmp.tgz", "-C", "/src", "."], volumes={<ntfy-data volume>: {"bind": "/src", "mode": "ro"}, "infra-backups": {"bind": "/backups"}}, remove=True)`, then rename.
  - Flow: run the three tasks independently (one failing doesn't skip the others), prune each target with `BACKUP_KEEP`, write `metrics/backup.prom` with `write_atomic`, then raise if any task failed so the run shows red.
- [ ] **Step 4: Run the tests and confirm they pass.** Same command as Step 2, plus `test_serve.py`. Expected: every `ok …` line, exit 0.
- [ ] **Step 5: Backup-age rule.** Add to group `infra`: title `Backup stale`, query `time() - infra_backup_last_success_timestamp_seconds`, condition `A > 93600` (26 h), for `0m`. Add a second rule, `Backup metric missing`, query `absent(infra_backup_last_success_timestamp_seconds)`, condition `A > 0`, for `30m`.
- [ ] **Step 6:** Commit. The PR stays open for Task 12.

```bash
git add prefect/flows/backup.py prefect/flows/test_backup.py prefect/flows/test_serve.py prefect/flows/serve.py monitoring/grafana/provisioning/alerting/rules.yml CLAUDE.md
git commit -m "feat(backups): nightly backup flow for postgres, neo4j and ntfy, with freshness alert"
```

### Task 12: OpenBao snapshot with a scoped token (items 1 + 12)

**Files:**
- Create: `openbao/policies/backup.hcl`: `path "sys/storage/raft/snapshot" { capabilities = ["read"] }` and `path "auth/token/renew-self" { capabilities = ["update"] }`
- Create: `scripts/vault-backup-token.sh`
- Modify: `Makefile` (`vault-backup-token` target, no `check-env`, like the other `vault-*` targets)
- Modify: `prefect/flows/backup.py` (task `dump_openbao() -> Path`, added to the flow and to `metrics_text`)
- Modify: `prefect/flows/test_backup.py`
- Modify: `CLAUDE.md` "Secrets (OpenBao)" (change the sentence "no app … reads its secrets from the vault yet")

**Interfaces:**
- Produces: `make vault-backup-token`. It writes policy `backup` from the file, creates `bao token create -policy=backup -period=768h -orphan -display-name=prefect-backup`, and prints the token **once** to stdout. It reads the root token from `.openbao.env` and passes it with `docker compose exec -e BAO_TOKEN`, like `vault-cli.sh`.
- Produces: Prefect Secret block `openbao-backup-token`.

- [ ] **Step 1: Failing test.** `test_openbao_renews_then_snapshots`: with `urllib.request.urlopen` monkeypatched to record requests and return bytes, `dump_openbao.fn()` makes exactly two requests, in order: `POST http://openbao:8200/v1/auth/token/renew-self` and `GET http://openbao:8200/v1/sys/storage/raft/snapshot`, both with header `X-Vault-Token`. The returned path ends in `.snap`. Run it and confirm it fails.
- [ ] **Step 2: Implement** `dump_openbao`. The token comes from `Secret.load("openbao-backup-token").get()`, the address from `BACKUP_BAO_ADDR` (default `http://openbao:8200`), and the body goes through `write_atomic`. Run the tests and confirm they pass.
- [ ] **Step 3: Write `vault-backup-token.sh`.** Run it on the host and paste the token into Prefect UI → Blocks → Secret `openbao-backup-token`.
- [ ] **Step 4: Commit, open PR G (Tasks 10–12), merge, deploy.** Then trigger the `backup/nightly` deployment from the Prefect UI. Expected:
  - the run completes
  - `docker run --rm -v infra-backups:/b alpine find /b -type f` lists one file under each of `postgres/`, `neo4j/`, `ntfy/`, `openbao/` plus `metrics/backup.prom`
  - Grafana Explore `infra_backup_last_success_timestamp_seconds` has 4 series
  - `bao audit` lines in Loki show `display_name=token-prefect-backup`

```bash
git commit -am "feat(backups): OpenBao raft snapshot via a scoped periodic token (the vault's first consumer)"
```

### Task 13: Heaven snapshots the dumps, restore proven (item 1, part 3)

Blocked on **D1** and **D2**.

**Files:**
- Heaven repo: `docker-compose.yml` (`volumes: infra-backups: {external: true}`) and its `.env`: `HEAVEN_SOURCES_PATH=infra-backups`, `HEAVEN_REPOSITORY_PATH=<D1>`, `TZ=America/Toronto` (it defaults to Europe/Paris, so its 02:30 would run before the 01:30 Toronto dump), `HEAVEN_SCHEDULE=03:00`
- Create in this repo: `docs/runbooks/restore.md`

- [ ] **Step 1:** Open the Heaven PR with the change above, merge it, redeploy Heaven. The next morning, `heaven snapshots` (or the UI) shows a snapshot containing `postgres/…sql.gz`.
- [ ] **Step 2: Postgres restore drill.** Restore the latest snapshot to a temp dir, then `docker run --rm -d --name pg-restore -e POSTGRES_PASSWORD=x <pgvector image pinned in Task 6>`, then `gunzip -c postgres-*.sql.gz | docker exec -i pg-restore psql -U postgres`. Expected: `\l` lists `keycloak`, `grafana`, `litellm`, `prefect` and every `APP_DATABASES` entry, and `select count(*) from keycloak.public.user_entity` (connect with `-d keycloak`) matches production.
- [ ] **Step 3: OpenBao restore drill.** Start a throwaway `openbao` with the same `config.hcl` and a **copy** of `seal.key` on an empty volume, initialise it, then `bao operator raft snapshot restore -force <file>`. Expected: `bao kv get infra/env` returns the production keys. Record every command in `restore.md`.
- [ ] **Step 4: Neo4j and ntfy.** Write the restore commands in `restore.md` (`neo4j-admin database load --from-path`; untar into an empty volume). Running them is optional.
- [ ] **Step 5: Seal key (D2).** Confirm a copy of `openbao/seal.key` exists at the D2 location, and that its `sha256sum` matches the host's. Write the location (not the key) in `restore.md`.
- [ ] **Step 6: Commit `docs/runbooks/restore.md`** (docs-only, so no deploy). Add a recurring reminder to repeat Steps 2–3 every quarter.

```bash
git add docs/runbooks/restore.md && git commit -m "docs(backups): restore runbook, drilled for postgres and openbao"
```
