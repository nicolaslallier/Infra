# Sessions de dev Claude Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un CLI Rust `devbox` qui crée, liste, arrête, reprend et supprime des sessions Claude Code isolées (un conteneur par dépôt git), joignables en SSH à travers le NGINX d'infra.

**Architecture:** Une pile Portainer par session (compose unique `dev/session.compose.yml`, paramétré par variables d'environnement, créée par le CLI via l'API Portainer). Les sessions vivent sur un réseau Docker `internal` (`dev-net`) ; leurs seuls ponts sont un proxy de sortie à liste blanche de domaines (squid) et une passerelle SSH (`sshd` en `ProxyJump`, `PermitOpen dev-*:2222`) que NGINX expose sur `${LAN_IP}:2222`. `/work` et `~/.claude` sont synchronisés vers un bucket SeaweedFS versionné (rclone).

**Tech Stack:** Rust (clap, reqwest/rustls, serde, dialoguer, toml), Docker Compose, squid, OpenSSH, rclone, Node/Python/Rust dans l'image.

**Spec:** `docs/superpowers/specs/2026-11-07-dev-sessions-design.md`

## Global Constraints

- Images épinglées `tag@sha256` (digest d'index, `docker buildx imagetools inspect`), comme le reste du dépôt ; l'image de session est construite sur le daemon (`pull_policy: never`), comme `ollama-proxy`.
- Aucun `ports:` sur un backend ; seul `nginx` publie, et le port SSH est lié à `${LAN_IP:?Set LAN_IP in .env}`, jamais `0.0.0.0`.
- Résolution NGINX paresseuse : `resolver` + `set $upstream` (modèle `nginx/stream.d/rabbitmq.conf`).
- Aucune clé Portainer, aucun socket Docker, aucun `infra-net` dans une session.
- Sortie des sessions : uniquement Anthropic, GitHub, crates.io, npmjs, PyPI (+ CDN) et `s3:8333` ; jamais une IP privée (RFC1918) sauf `s3`.
- Jeton GitHub : un seul dépôt ; jamais affiché par le CLI ni écrit dans un fichier du dépôt.
- Nom de session : `^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$` (sert d'hôte `dev-<nom>`, de préfixe S3 et de nom de pile).
- Plafond de sessions actives : 4 par défaut ; `mem_limit` 1536m par défaut.
- Utilisateur non-root `dev`, sans sudo, sshd interne sur le port 2222.
- Les nouveaux fichiers doivent être commités avant tout `make up` (drift guard).

## Review Focus

- URL de dépôt non GitHub, avec `.git`, ou au format `git@github.com:o/r` : normalisée en `o/r` ou refusée avec un message clair.
- Nom de session avec majuscule, `_`, espace, trop long ou `..` : refusé avant tout appel réseau.
- `create` d'un nom dont la pile existe déjà : refusé ; d'un nom supprimé mais dont le bucket a des données : restaure depuis le bucket.
- `stop` : la synchro finale va au bout (`stop_grace_period`) ; un crash perd au plus l'intervalle de synchro.
- Le jeton GitHub n'apparaît dans aucune sortie de `list`, `create` ni dans les journaux du CLI (`Debug` masqué).
- Plafond atteint : `create` et `resume` refusent avec le nombre actif et le plafond.

---

### Task 1: Image de session et compose de session

**Files:**
- Create: `dev/image/Dockerfile`, `dev/image/entrypoint.sh`, `dev/image/sync.sh`
- Create: `dev/session.compose.yml`
- Modify: `Makefile` (cible `dev-image`, hors `up`/`init`)

**Interfaces:**
- Produces: image `devbox-session:1` ; `dev/session.compose.yml` lisant les variables `SESSION`, `REPO_URL`, `GH_TOKEN`, `PLUGINS` (liste `plugin@marketplace` séparée par des virgules), `SSH_PUBKEY`, `S3_SECRET_KEY`, `MEM_LIMIT` (défaut `1536m`) ; conteneur nommé `dev-${SESSION}`, sur le réseau externe `dev-net`, volume nommé `dev-${SESSION}-work`.

- [ ] **Step 1: Test de fumée de l'image (écrit d'abord)** : `scripts/dev-image-check.sh` lance `docker run --rm devbox-session:1` pour `node --version`, `python3 --version`, `rustc --version`, `cc --version`, `pkg-config --version`, `claude --version`, `gh --version`, `rclone version`, `id -u` (doit valoir autre chose que 0) et `sudo` (doit être absent). Sortie attendue : code 0 si tout passe.
- [ ] **Step 2: Lancer le test** ; Expected: FAIL (image absente).
- [ ] **Step 3: `dev/image/Dockerfile`** : base Debian bookworm épinglée ; Node LTS, Python 3, rustup (profil minimal, `cargo`, `clippy`), build-essential, pkg-config, libssl-dev, git, gh, rclone, openssh-server, `@anthropic-ai/claude-code` ; utilisateur `dev` (uid 1000), ENTRYPOINT `entrypoint.sh`.
- [ ] **Step 4: `entrypoint.sh`** (bash, `set -euo pipefail`) dans cet ordre : écrit `SSH_PUBKEY` dans `~/.ssh/authorized_keys` ; génère la clé d'hôte dans `~/.ssh/` si absente ; configure rclone (remote `s3`, endpoint `http://s3:8333`, clé d'accès `devbox`, secret `S3_SECRET_KEY`) ; si le préfixe `devbox/<SESSION>/` du bucket existe, restaure `/work` et `~/.claude` par `sync.sh restore`, sinon `gh repo clone` de `REPO_URL` dans `/work` ; `gh auth setup-git` avec `GH_TOKEN` ; installe chaque entrée de `PLUGINS` par `claude plugin marketplace add` puis `claude plugin install` (échec d'un plugin = avertissement, pas arrêt) ; lance `sync.sh loop` en arrière-plan ; lance `sshd -D -e -p 2222` sans PAM ; sur SIGTERM, fait `sync.sh push` puis sort.
- [ ] **Step 5: `sync.sh`** avec les sous-commandes `push`, `restore`, `loop` (push toutes les `SYNC_INTERVAL` secondes, 60 par défaut). `push` : `rclone sync` de `/work` (exclut `target/`, `node_modules/`, `.venv/`) vers `devbox:<SESSION>/work`, et de `~/.claude` (inclut `.credentials.json`) vers `devbox:<SESSION>/claude`. Pas de `--delete-excluded`.
- [ ] **Step 6: `dev/session.compose.yml`** : `container_name: dev-${SESSION:?}`, `image: devbox-session:1`, `pull_policy: never`, `mem_limit`, `stop_grace_period: 120s`, `restart: unless-stopped`, `read_only: false`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, aucun `ports:`, aucun montage hôte ; environnement `HTTP_PROXY`, `HTTPS_PROXY` = `http://dev-egress:3128`, `NO_PROXY` vide ; réseau `dev-net` externe.
- [ ] **Step 7: `make dev-image`** construit `devbox-session:1` sur le daemon (même mécanisme que `app-images`, lire `scripts/portainer-images.sh` avant). Lancer `scripts/dev-image-check.sh`; Expected: PASS.
- [ ] **Step 8: Commit** `feat(dev): image de session Claude Code et compose de session`.

### Task 2: Réseaux, proxy de sortie, passerelle SSH, NGINX

**Files:**
- Create: `docker-compose.dev.yml` (projet `dev`), `dev/egress/squid.conf`, `dev/gateway/Dockerfile`, `dev/gateway/sshd_config`, `dev/gateway/authorized_keys`
- Create: `nginx/stream.d/devssh.conf`, `scripts/dev-isolation-check.sh`
- Modify: `docker-compose.yml` (port `${LAN_IP:?Set LAN_IP in .env}:2222:2222` sur `nginx`), `Makefile` (`dev-up`, `dev-down`, `dev-logs`, `dev-status`, sur le modèle `runner-*`)

**Interfaces:**
- Consumes: Task 1, réseau externe `infra-net`.
- Produces: réseau `dev-net` (`internal: true`, nom fixe, `external` côté sessions), conteneurs `dev-egress` (`:3128`) et `dev-gateway` (`:22`, utilisateur `jump`), `nginx` écoutant `2222` → `dev-gateway:22`.

- [ ] **Step 1: Écrire `scripts/dev-isolation-check.sh <session>`** : exécute dans `dev-<session>` (`docker exec`) et vérifie, via le proxy : `https://api.anthropic.com` joignable (tout code HTTP, pas d'erreur de proxy) ; `https://github.com`, `https://static.crates.io`, `https://registry.npmjs.org`, `https://pypi.org` joignables ; `https://example.com` refusé (403) ; `http://192.168.2.35:11434` refusé ; `http://postgres:5432` et `http://nginx` injoignables ; `http://s3:8333` joignable ; accès direct sans proxy (`curl --noproxy '*' https://github.com`) impossible ; `/var/run/docker.sock` absent. Affiche une ligne OK/KO par contrôle, code 1 au premier KO.
- [ ] **Step 2: `docker-compose.dev.yml`** : réseaux `dev-net` (`name: dev-net`, `internal: true`) et `dev-out` (bridge normal). `dev-egress` sur `dev-net`, `dev-out` et `infra-net` (pour `s3`) ; `dev-gateway` sur `dev-net` et `infra-net` ; aucun `ports:`. Images construites/épinglées comme au Global Constraints.
- [ ] **Step 3: `dev/egress/squid.conf`** : ordre des règles — autoriser `s3:8333` ; refuser tout `dst` privé (10/8, 172.16/12, 192.168/16, 127/8, 169.254/16) ; autoriser `dstdomain` de la liste blanche (`.anthropic.com`, `.claude.ai`, `.github.com`, `.githubusercontent.com`, `.crates.io`, `.rust-lang.org`, `.npmjs.org`, `.npmjs.com`, `.pypi.org`, `.pythonhosted.org`) en CONNECT 443 et http 80 ; `http_access deny all` ; pas de cache, journaux sur stdout.
- [ ] **Step 4: Passerelle** : `sshd_config` avec `PasswordAuthentication no`, `AllowUsers jump`, `PermitOpen dev-*:2222`, `AllowTcpForwarding local`, `X11Forwarding no`, `ForceCommand /bin/false`, `PermitTTY no` ; `authorized_keys` contient la clé publique du propriétaire (placeholder commenté à remplacer, vérifié non vide par `make dev-up`).
- [ ] **Step 5: `nginx/stream.d/devssh.conf`** sur le modèle exact de `rabbitmq.conf` : `listen 2222`, `set $ssh dev-gateway:22`, `proxy_timeout 12h`. Ajouter le port dans `docker-compose.yml`. Lancer `make test` ; Expected: les checks nginx du `pr-validation` passent.
- [ ] **Step 6: Cibles `make dev-up` etc.** : `docker compose -p dev -f docker-compose.dev.yml` ; `dev-up` dépend de `check-env` et refuse si `dev/gateway/authorized_keys` n'a pas de clé.
- [ ] **Step 7: Vérifier** : `make dev-up`, créer une session à la main (`docker compose -p dev-test -f dev/session.compose.yml` avec des variables factices, `SESSION=test`), lancer `scripts/dev-isolation-check.sh test` ; Expected: tous OK. Puis `ssh -J jump@<LAN_IP>:2222 dev@dev-test` ouvre un shell. Nettoyer la session de test.
- [ ] **Step 8: Commit** `feat(dev): proxy de sortie, passerelle SSH et port NGINX`.

### Task 3: Identité S3 et variables d'environnement

**Files:**
- Modify: `.env.example`, `scripts/check-env.sh`, `CLAUDE.md` (courte section « Sessions de dev », avec le piège du bucket partagé)

**Interfaces:**
- Produces: identité S3 `devbox` limitée au bucket versionné `devbox` ; clé `DEVBOX_S3_SECRET_KEY` dans `.env`.

- [ ] **Step 1: Test** : un cas de rejet dans `scripts/test.sh`, sur le modèle de `MORIA_AMQP_PASSWORD`, où `check-env.sh` rejette un `.env` avec `DEVBOX_S3_SECRET_KEY` absent ou `change-me`. Lancer `make test`; Expected: FAIL.
- [ ] **Step 2:** Ajouter la clé à `.env.example` et la règle à `check-env.sh` (même forme que `PREFECT_S3_SECRET_KEY`, chercher comment elle est câblée). `make test`; Expected: PASS.
- [ ] **Step 3:** `make s3-provision app=devbox versioned=1` (noter que toutes les sessions partagent l'identité : un conteneur compromis peut lire les préfixes des autres ; ceiling documenté dans `CLAUDE.md`, remède : une identité par session).
- [ ] **Step 4: Commit** `feat(dev): identité S3 devbox et check-env`.

### Task 4: Squelette du CLI, configuration et validation (fonctions pures)

**Files:**
- Create: `dev/cli/Cargo.toml`, `dev/cli/src/main.rs`, `dev/cli/src/config.rs`, `dev/cli/src/validate.rs`

**Interfaces:**
- Produces (`validate.rs`): `pub fn session_name(s: &str) -> Result<&str, String>` ; `pub fn repo_slug(url: &str) -> Result<String, String>` (retourne `owner/repo`).
- Produces (`config.rs`): `pub struct Config { portainer_url: String, api_key: String, endpoint_id: u32, insecure_tls: bool, ssh_host: String, ssh_port: u16, pubkey_path: PathBuf, catalogs: Vec<String>, s3_secret_key: String, max_active: usize, mem_limit: String }` avec `Config::load() -> Result<Config>` (fichier `config.toml` du dossier de config de l'OS, `directories`), `Debug` masquant `api_key` et `s3_secret_key`.

- [ ] **Step 1: Tests `validate.rs`** : `session_name("jarvis")` ok ; refusés : `"Jarvis"`, `"a"`, `"a_b"`, `"-ab"`, `"ab-"`, un nom de 33 caractères, `"a..b"`, `""`. `repo_slug` : `https://github.com/o/r`, `https://github.com/o/r.git`, `git@github.com:o/r.git`, `o/r` donnent `o/r` ; `https://gitlab.com/o/r`, `https://github.com/o` et `https://github.com/o/r/extra` sont refusés.
- [ ] **Step 2:** `cargo test -p devbox validate`; Expected: FAIL.
- [ ] **Step 3:** Implémenter les deux fonctions (regex du Global Constraints, pas de dépendance `regex` si une vérification manuelle suffit).
- [ ] **Step 4: Test `config.rs`** : `format!("{:?}", config)` ne contient ni l'`api_key` ni le `s3_secret_key` ; un fichier TOML sans `catalogs` donne `["anthropics/claude-plugins-official"]` ; `max_active` vaut 4 et `mem_limit` `1536m` par défaut.
- [ ] **Step 5:** Implémenter `Config`, `main.rs` avec les sous-commandes clap `create`, `list`, `stop`, `resume`, `delete` (corps `todo!()` jusqu'à Task 6). `cargo test`; Expected: PASS.
- [ ] **Step 6: Commit** `feat(devbox): configuration et validation`.

### Task 5: Catalogue de plugins

**Files:**
- Create: `dev/cli/src/catalog.rs`

**Interfaces:**
- Consumes: `Config.catalogs`.
- Produces: `pub struct Plugin { pub id: String /* plugin@marketplace */, pub description: String }` ; `pub fn parse_marketplace(json: &str) -> Result<Vec<Plugin>, String>` ; `pub fn fetch_all(catalogs: &[String]) -> Result<Vec<Plugin>, String>` (clone superficiel `https://github.com/<c>` en répertoire temporaire, lit `.claude-plugin/marketplace.json`).

- [ ] **Step 1: Tests** : `parse_marketplace` sur un JSON `{ "name": "m", "plugins": [{"name":"p","description":"d"}] }` donne `Plugin { id: "p@m", description: "d" }` ; JSON invalide ou sans `plugins` donne `Err` ; `description` absente donne une chaîne vide. `fetch_all` n'est pas testé (réseau), il ne contient que du git et de l'E/S.
- [ ] **Step 2:** Lancer ; Expected: FAIL. **Step 3:** Implémenter ; un catalogue injoignable donne un avertissement et la liste des autres, pas un échec. **Step 4:** Lancer ; Expected: PASS.
- [ ] **Step 5: Commit** `feat(devbox): catalogue de plugins`.

### Task 6: Client Portainer et commandes de session

**Files:**
- Create: `dev/cli/src/portainer.rs`, `dev/cli/src/github.rs`, `dev/cli/src/session.rs`
- Modify: `dev/cli/src/main.rs`

**Interfaces:**
- Consumes: `Config`, `validate::*`, `catalog::fetch_all`, `dev/session.compose.yml` (inclus par `include_str!("../../session.compose.yml")`).
- Produces (`portainer.rs`): `Client::new(&Config)` ; `list_stacks() -> Vec<Stack { id: u32, name: String, running: bool }>` ; `create_stack(name: &str, compose: &str, env: &[(String,String)])` ; `stop(id)`, `start(id)`, `delete(id)` ; en-tête `X-API-Key`. Piles de session nommées `dev-<nom>` ; `list` filtre sur ce préfixe.
- Produces (`github.rs`): `pub fn main_is_protected(slug: &str, token: &str) -> Result<bool, String>` (GET `/repos/{slug}/branches/main`, champ `protected`).
- Produces (`session.rs`): `pub fn stack_env(cfg: &Config, name: &str, repo: &str, token: &str, plugins: &[String], pubkey: &str) -> Vec<(String,String)>` ; `pub fn check_cap(active: usize, max: usize) -> Result<(), String>` ; `pub fn ssh_config_entry(cfg: &Config, name: &str) -> String`.

- [ ] **Step 1: Tests `session.rs`** : `stack_env` contient exactement `SESSION`, `REPO_URL` (`https://github.com/<slug>`), `GH_TOKEN`, `PLUGINS` (liste jointe par `,`), `SSH_PUBKEY`, `S3_SECRET_KEY`, `MEM_LIMIT` ; `check_cap(3, 4)` ok, `check_cap(4, 4)` donne une erreur contenant `4`; `ssh_config_entry` pour `jarvis` vaut un bloc `Host dev-jarvis` avec `HostName dev-jarvis`, `User dev`, `Port 2222`, `ProxyJump jump@<ssh_host>:<ssh_port>`.
- [ ] **Step 2:** Lancer ; Expected: FAIL. **Step 3:** Implémenter. **Step 4:** Lancer ; Expected: PASS.
- [ ] **Step 5: `create <nom> [--repo URL] [--plugin id ...]`** : valide le nom ; refuse si une pile `dev-<nom>` existe ; `check_cap` sur les piles `running` ; demande l'URL (dialoguer) si absente, la normalise ; demande le jeton (saisie masquée) ; refuse si `main_is_protected` est faux, avec le message « active la protection de `main` d'abord » ; propose les plugins par sélection multiple (`fetch_all`) si `--plugin` absent ; crée la pile ; ajoute l'entrée SSH à `~/.ssh/config` si absente (jamais de doublon) ; affiche `ssh dev-<nom>` et, au premier lancement, la commande `claude` à exécuter pour le login par abonnement.
- [ ] **Step 6: `list`** (nom, état, dépôt non affiché si inconnu) ; **`stop`** (stop de la pile, attend que la pile soit arrêtée) ; **`resume`** (`check_cap`, puis start) ; **`delete <nom>`** (confirmation, supprime la pile et son volume ; `--purge` supprime aussi `devbox/<nom>/` du bucket via `rclone` lancé en conteneur éphémère sur `infra-net`… à défaut, documente la commande manuelle et ne purge pas). Aucune sortie n'affiche le jeton.
- [ ] **Step 7: Acceptation de bout en bout** : `cargo build --release` ; `devbox create essai --repo <un dépôt de test>` ; `ssh dev-essai` donne un shell ; `claude` demande le login ; `scripts/dev-isolation-check.sh essai` tout OK ; `devbox stop essai` puis `devbox resume essai` retrouvent `/work` et `~/.claude` intacts ; `devbox delete essai` puis `devbox create essai` avec le même dépôt restaure depuis le bucket ; `devbox list` ne montre le jeton nulle part (`docker logs` non plus).
- [ ] **Step 8: Commit** `feat(devbox): commandes create, list, stop, resume, delete`.

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (section « Sessions de dev » : architecture, pièges, ce que garde le jeton GitHub), `README.md` (utilisation du CLI), `Makefile` (aide)

- [ ] **Step 1:** Rédiger les deux sections ; y consigner en une phrase chacun : la passerelle `ProxyJump`, le réseau `internal` + proxy comme seule sortie, le bucket partagé (ceiling), le jeton GitHub comme vrai garde-fou, la clé Portainer sur la machine du propriétaire.
- [ ] **Step 2:** `make test`; Expected: PASS. **Step 3: Commit** `docs(dev): sessions de dev`.

---

**Auto-relecture.** Couverture du spec : CLI + 5 commandes (T4–T6), plugins mélangés (T5), image prête à compiler sans Docker (T1), isolation sortie/hôte (T1, T2), SSH via NGINX sur `${LAN_IP}` (T2), SeaweedFS (T1, T3), plafond et mémoire (T4, T6, T1), protection de `main` (T6), documentation (T7). Types cohérents : `Config`, `stack_env`, `check_cap`, `ssh_config_entry` ont la même forme dans les Interfaces et les tâches. Risque connu : la purge du bucket (`--purge`) est volontairement minimale (T6 step 6).
