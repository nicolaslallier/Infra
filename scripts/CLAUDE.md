# Docker Desktop runtime notes

Moved out of the root CLAUDE.md so it loads only when working on scripts.

## Runtime: Docker Desktop

The stack runs on **Docker Desktop for Mac**, sized **6 CPU / 12 GB / 100 GB**
under Settings → Resources — the defaults cannot hold Keycloak's JVM,
Postgres, the whole LGTM stack, SeaweedFS and RabbitMQ at once. Sibling app repos
(Jarvis and others) share this same daemon and context automatically; there is
no per-repo VM.

This replaced a **Colima** VM. Notes mentioning `colima start`,
`~/.colima/_lima`, `socket_vmnet`, bridged networking or `make vm-start`
describe that old runtime and no longer apply. Two things changed that are
not cosmetic — what `LAN_IP` means, and what the `dns` container sees as a
client address. Both are below.

**The one thing the migration can silently get wrong** is the daemon the
`docker` CLI talks to. A leftover `docker context use colima`, `DOCKER_HOST`,
or `DOCKER_CONTEXT` still resolves, so `make up` would bring the whole stack
back up on the old VM, against the old volumes, and look entirely healthy.
`scripts/check-docker.sh` asserts `docker info` reports Docker Desktop and
fails the build otherwise; that check is the reason it exists.

### The disk image must live on the external volume

Point **Settings → Resources → Advanced → "Disk image location"** at
`/Volumes/Docker`. The Mac's internal SSD has under 90 GB free, and Docker
Desktop's sparse disk image grows toward the VM's full 100 GB. (Docker
Desktop used a `~/Library/Containers/com.docker.docker/Data` symlink to
`/Volumes/Docker` on this machine historically; the built-in setting is the
supported way and `check-docker.sh` accepts either.)

**Do not start Docker Desktop while that volume is unmounted.** Unlike
Colima, which refused, Docker Desktop builds a *fresh empty VM* in the
default location and comes up looking fine — a new Postgres cluster, no app
databases, no Keycloak realms, an empty object store. `scripts/check-docker.sh`
therefore checks the disk image location *first*, before it even asks
whether a daemon is reachable, so `make docker-start` can refuse to launch
the app rather than discovering the problem afterwards.

### `LAN_IP` is the Mac's address now, not a VM's

Colima ran bridged, with the VM holding its own DHCP lease, and `LAN_IP` was
*the VM's* address. Docker Desktop has no bridged mode: it publishes
container ports on the Mac itself. So `LAN_IP` is now **this Mac's** LAN IP
(`ipconfig getifaddr en1`), and `ports: ["${LAN_IP}:53:53/udp", ...]` on the
`dns` service binds the Mac's LAN interface directly. Move the router's
static DHCP reservation from the VM's MAC to the Mac's.

What this buys and costs:

- **UDP/53 works.** Bridged mode existed because Colima's default `ssh`
  port-forwarder does not forward UDP at all. Docker Desktop's forwarder
  does, so Technitium answers LAN clients through ordinary port publishing
  and none of that machinery is needed.
- **The `dns` container no longer sees real client addresses.** Docker
  Desktop's forwarder rewrites the source IP to its internal gateway, so
  every query arrives from one address. `DNS_SERVER_RECURSION` is still
  satisfied (that gateway is a private address, and the policy is
  `AllowOnlyForPrivateNetworks`), but Technitium's per-client ACLs,
  stats and query logs now describe the forwarder, not the phone that
  asked. Do not build anything on them.
- macOS prompts once to allow incoming connections, and nothing else may
  already hold `:53` on that address.

`127.0.0.1:5432` and `127.0.0.1:5672` on the `nginx` service now bind the
Mac's loopback directly, with no Lima forwarder in the path — simpler than
before. Keep them on `127.0.0.1` rather than `${LAN_IP}`: binding them to the
LAN address would expose Postgres and AMQP to every device on the network and
defeat the single-ingress rule.

### Bind mounts and file sharing

Docker Desktop shares `/Users`, `/Volumes`, `/private` and `/tmp` by default
(Settings → Resources → File sharing). A repo outside those resolves to an
empty auto-created directory *inside the VM*, and the stack then fails the
same split way it did under a mountless Colima VM:

- services mounting a single file (`loki`, `tempo`, `prometheus`, `alloy`,
  `nginx`, `oauth2-proxy`, `rabbitmq`) die with
  `error mounting ".../monitoring/loki/config.yml": ... not a directory`
- services mounting a directory (`grafana` provisioning, `postgres` initdb,
  `keycloak` realm-import) start **successfully against empty config**

`scripts/check-docker.sh` checks the repo path against the shared roots so
this surfaces as one clear error instead of half a stack behaving oddly.

### Preflight: `make check-docker` / `make docker-start`

`scripts/check-docker.sh` reports state as an exit code, the same pattern the
old `check-vm.sh` used:

| code | meaning |
|---|---|
| 0 | running, Docker Desktop, repo bind-mountable, sized right |
| 1 | the disk image location does not resolve (external volume unmounted) |
| 2 | no docker CLI, or no reachable daemon (Docker Desktop is not running) |
| 3 | a daemon answers, but it is not Docker Desktop |
| 4 | the repo is outside Docker Desktop's shared directories |
| 5 | usable, but under-sized or storing its disk image on the internal SSD |

Setting `SKIP_DOCKER_CHECK=1` short-circuits the whole script to 0. Every
check in it is macOS/Docker-Desktop specific, so that is the escape hatch for
the non-Mac environments this stack is also brought up in (CI, a cloud dev
VM, a plain Linux `dockerd` — see `AGENTS.md`); the compose stack itself is
portable.

`make check-docker` (a prerequisite of `up`, `config` and `portainer-up`)
fails the build on 1–4 and only warns on 5, since a small VM or a misplaced
disk image degrades the stack rather than breaking it. `make docker-start`
reads the same code: it no-ops when the daemon is already correct, refuses on
1 (mount the volume first), launches Docker.app and waits up to three minutes
on 2, and re-checks afterwards.

### Autostart

Settings → General → **"Start Docker Desktop when you sign in"** brings the
daemon up at login, and the containers' `restart: unless-stopped` follows.
Turn off "put hard disks to sleep when possible" in Energy settings: a
spin-down under a live disk image stalls every container.

The autostart caveat is the mirror of Colima's. Colima's flagless
`brew services` start silently rebuilt a small, mountless VM; Docker Desktop
keeps its Settings across restarts, so the sizing and file-sharing config
persist — but it will happily start with `/Volumes/Docker` absent and build
an empty VM there and then. That is why `check-docker.sh`'s disk-image check
runs before anything else, and why `make up` runs it every time.

### Migrating the volumes off the old Colima VM

Named volumes live inside the daemon's own VM: switching contexts does not
bring them along. With both daemons installed and the stack stopped on both:

```bash
make migrate-volumes DRY=1   # list what would be copied
make migrate-volumes         # colima -> desktop-linux, streamed through tar
```

`scripts/migrate-volumes.sh` enumerates the volumes by their
`com.docker.compose.project` label (falling back to the `<project>_` name
prefix), refuses to run while any of the project's containers are up on
either daemon — copying a live Postgres data directory yields a corrupt
cluster — and skips volumes that already hold data on the target unless
`OVERWRITE=1`. It never modifies the source. Data that is *not* in a volume
(`certs/`, `.env`, everything bind-mounted from the repo) needs nothing: it
lives in the working tree.

After migrating, re-run `make provision-app app=<name>` for each app — it is
idempotent, and it is what re-asserts the `vector` extension and the
`CONNECT` revocation if anything was missed.

## Preflight: `make check-env`

`scripts/check-env.sh` refuses to let anything deploy or provision against
a `.env` that cannot bring the stack up. Everything it finds goes to stderr
— warnings first, then the blockers — and it exits 1 if there was a blocker,
having reported all of them rather than the first. Every check is there
because the failure it prevents surfaces somewhere other than `.env`:

- **Settings `.env.example` defines that this `.env` never got.** `.env` is
  copied once, by `make init`, and then lives on (gitignored) while
  `.env.example` keeps growing — so a variable introduced with a new service
  is simply absent from a long-lived `.env`. Compose interpolates an absent
  variable as an **empty string and deploys anyway**, so the symptom is a
  container dying on its own config with nothing naming `.env`:
  `oauth2-proxy-ea`, handed an empty `EA_OBSIDIAN_OAUTH_COOKIE_SECRET`,
  logs `invalid configuration: missing setting: cookie-secret` and
  crash-loops. The check diffs the assigned keys of the two files and prints
  the missing lines ready to append. Keys assigned only inside a comment in
  `.env.example` (`PORTAINER_API_KEY`, which belongs in `.portainer.env`)
  are not keys and never trip it. To decline a setting that has a Compose
  `:-` default (`UPSTREAM_DNS`, `GRAFANA_ADMIN_USER`), keep its line and
  leave the value empty rather than deleting it.
- **Placeholders, empties, and absences** in the password-like values with
  no source other than `.env` — the `change-me` check — plus a
  `<APP>_DB_PASSWORD` for every entry in `APP_DATABASES` (an app added to
  that list by hand has no `.env.example` line to diff against, hence the
  separate loop). The three states are reported separately because they are
  three different mistakes.
- **oauth2-proxy cookie keys of the wrong length *or alphabet*.**
  oauth2-proxy accepts only a 16, 24 or 32 byte `cookie-secret` and dies at
  startup otherwise, so `JARVIS_OAUTH_COOKIE_SECRET` /
  `EA_OBSIDIAN_OAUTH_COOKIE_SECRET` are checked rather than just checked
  for being filled in. The check mirrors `pkg/encryption.SecretBytes`
  rather than asking "is this base64 of 32 bytes", because the container
  does not: it decodes with Go's `base64.RawURLEncoding` — the **URL-safe**
  alphabet — and falls back to the *raw string* when that fails. So a
  standard-base64 key is a 44-byte key to it
  (`cookie_secret must be 16, 24, or 32 bytes ... but is 44 bytes`), and
  `openssl rand -base64 32` alone produces one about three times in four.
  Hence the `| tr -- '+/' '-_'` on every generation recipe in `.env.example`,
  the README and the `:?` guards, and hence check-env naming that case
  specially: the fix is to re-spell the existing key, not to mint a new one
  (which invalidates every live session). The decode itself must stay
  portable, and `-d` is the only spelling that is: busybox has neither
  `--decode` nor `-D`, and busybox is what `base64` is inside the Alpine
  container `scripts/ci-deploy.sh` runs `make` in. With `set -o pipefail` on,
  a failed decode there returned *no* length rather than a wrong one, so a
  valid 32-byte key read as a raw 44-byte one and every CI deploy failed a
  check that passed by hand on the same file.
- **A missing or wrong-sized `openbao/seal.key`.** The only check here that
  is not about a value in `.env`, and it is here for exactly the reason the
  rest are: it fails somewhere that never names the file. The key is
  bind-mounted into `openbao` as a *file*, and Docker silently auto-creates a
  **directory** for a bind mount whose source does not exist — so a checkout
  that ran `make init` before OpenBao existed deploys a vault that dies on
  "is a directory", with the whole secret store down. A key of the wrong
  length fails later and more obscurely still: the static seal is AES-256 and
  takes 32 bytes, nothing else. `make seal-key` generates it; it is
  gitignored, so it can never arrive with a `git pull`.
- **`LAN_IP` the host does not own.** `dns` publishes its ports on that
  address; a stale one (an old VM's, a changed DHCP lease) fails the bind
  and leaves every later service stuck in `Created`. Against a remote daemon
  (`DOCKER_HOST=ssh://…`, the normal Mac → Windows-laptop case) the
  addresses of *this* machine say nothing, so `LAN_IP` is compared to the
  Makefile's `INFRA_HOST` instead; standalone, that host is derived from
  `DOCKER_HOST`. Where neither `ifconfig` nor `ip` exists to enumerate
  addresses, the check passes rather than guessing.

The **two oauth2-proxy client secrets are warnings, never errors**:
Keycloak generates them when it imports a realm, so they cannot exist
before the first deploy — erroring on them would make the documented
bootstrap order (deploy, then copy the secret out of the admin console)
impossible. The warning names the realm and client to copy it from, and
which container crash-loops until then. For the same reason
`docker-compose.yml` guards the *cookie* secrets with
`${...:?Set ... in .env}` (like `LAN_IP` and `DNS_ADMIN_PASSWORD`) but
leaves the *client* secrets unguarded: the cookie key is required before
first boot and choosable offline, so failing the compose parse is right,
while a `:?` on the client secret would block the very deploy that creates
it. Non-Mac environments that run `docker compose up -d` directly
(CI, the cloud VM in `AGENTS.md`) never call `check-env`, so those `:?`
guards are the only thing standing between them and a silently empty value.
