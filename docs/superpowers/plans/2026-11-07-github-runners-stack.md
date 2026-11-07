# Stack Portainer des runners GitHub — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cinq runners GitHub (`darkangel`, `ea`, `heaven`, `infra`, `moria`) dans un seul `docker-compose.runners.yml` déployé comme stack Portainer `runners`, et `main` des cinq dépôts protégée par un ruleset strict.

**Architecture:** Un compose (projet `runners`) à cinq services issus d'une ancre YAML ; un script `scripts/runners-stack.sh` crée/redéploie la stack par l'API Portainer (Git stack, env = `.runner.env` seul) ; les scripts `gen-runner-env.sh` / `runner-status.sh` passent en multi-dépôts grâce à une table partagée `scripts/lib/runners.sh` ; `scripts/github-harden.sh` applique ruleset et réglages Actions via `gh api`, en dry-run par défaut.

**Tech Stack:** Docker Compose, Bash, `jq`, `gh`, Makefile, GitHub Actions, Python (check `pr_validation`).

**Spec:** `docs/superpowers/specs/2026-11-07-github-runners-stack-design.md`

## Global Constraints

- Image runner : `myoung34/github-runner:ubuntu-noble` (tag mouvant, voulu), `EPHEMERAL: "true"`, `RUNNER_SCOPE: repo`, `restart: unless-stopped`, hors `infra-net`.
- Services : `runner-darkangel`, `runner-ea`, `runner-heaven`, `runner-infra`, `runner-moria` ; `LABELS` = nom en minuscules (`darkangel`, `ea`, `heaven`, `infra`, `moria`) ; `RUNNER_NAME` = `<nom>-host` ; `REPO_URL` = `https://github.com/nicolaslallier/<Repo>` (`DarkAngel`, `EA`, `Heaven`, `Infra`, `Moria`).
- Socket Docker (`/var/run/docker.sock`) monté **uniquement** sur `darkangel`, `heaven`, `infra`. EA et Moria : aucun socket.
- Un PAT par dépôt : `GH_RUNNER_TOKEN_DARKANGEL|EA|HEAVEN|INFRA|MORIA`, dans `.runner.env` (gitignoré), garde `:?` sur chacun. Jamais dans `.env`.
- Le profil actuel d'EA est conservé : `extra_hosts` (`portainer.infra.famillelallier.net` et `vault.infra.famillelallier.net` → `${PORTAINER_HOST_IP:-192.168.2.10}`), `tmpfs: /_work:exec`, CA `${INFRA_DIR:-.}/certs/infra-ca.crt:/etc/ea/infra-ca.crt:ro`.
- Aucun workflow qui tourne sur un label self-hosted n'a de déclencheur `pull_request` / `pull_request_target`.
- Ruleset `main` (nom `main-protection`) : PR obligatoire, 0 approbation, checks requis + branche à jour, historique linéaire, conversations résolues, suppression et force-push interdits, `bypass_actors` vide. Commits signés : **non**.
- Les réglages GitHub ne s'appliquent qu'avec l'accord explicite du propriétaire, dépôt par dépôt ; Infra en dernier.
- Une cible qui recrée les runners refuse si un job tourne (exit 3), sauf `FORCE=1`.

## Review Focus

1. Un des cinq PAT absent de `.runner.env` : `make runners-up` échoue en nommant la variable (jamais quatre runners sur cinq en silence).
2. Un job en cours pendant `runners-up`/`-down`/`-restart`/`-pull` : refus exit 3, même si un seul des cinq runners est occupé.
3. Un PAT sans le bon scope sur un seul dépôt : `gen-runner-env.sh` refuse et nomme le dépôt ; `runner-status.sh` le signale par dépôt.
4. Check requis filtré par `paths` : une PR qui ne touche pas ces chemins reste bloquée à jamais ; `test.yml` n'a donc aucun filtre.
5. `github-harden.sh --apply` relancé : met à jour `main-protection`, ne crée pas de doublon, et ne touche pas les anciens rulesets `Main` / `Protect Main`.
6. Chemin du checkout hôte sous WSL (`/mnt/c/...`) : `INFRA_DIR` envoyé à Portainer doit être traduit comme `daemon_dir` le fait, sinon le CA d'EA devient un dossier vide.

---

## Fichiers

- Créer : `docker-compose.runners.yml`, `scripts/lib/runners.sh`, `scripts/runners-stack.sh`, `scripts/github-harden.sh`, `.github/workflows/test.yml`
- Modifier : `scripts/gen-runner-env.sh`, `scripts/runner-status.sh`, `Makefile` (section « CI runners »), `scripts/test.sh`, `prefect/flows/pr_validation.py` (`_checks`), `.env.example`, `README.md`, `AGENTS.md`, `CLAUDE.md`
- Supprimer : `docker-compose.runner.yml`, `docker-compose.runner-ea.yml`

---

### Task 1: Table partagée et compose des cinq runners

**Files:**
- Create: `scripts/lib/runners.sh`, `docker-compose.runners.yml`
- Modify: `scripts/test.sh` (nouvelle section), `prefect/flows/pr_validation.py` (`_checks`)

**Interfaces:**
- Produces (`scripts/lib/runners.sh`, à sourcer) : `RUNNERS=(darkangel:DarkAngel ea:EA heaven:Heaven infra:Infra moria:Moria)` ; `runner_repo <name> -> nicolaslallier/<Repo>` ; `runner_token_var <name> -> GH_RUNNER_TOKEN_<UPPERCASE>`.

- [ ] **Step 1: Écrire le test qui échoue** — dans `scripts/test.sh`, section `== runners compose`, avec un `.runner.env` factice de cinq jetons dans `$ws` : `docker compose -f docker-compose.runners.yml --env-file <fake> config --format json` puis `jq` assertent : exactement 5 services nommés `runner-<nom>` ; chacun a `LABELS == <nom>`, `EPHEMERAL == "true"` ; `/var/run/docker.sock` monté sur `darkangel`, `heaven`, `infra` et sur aucun autre ; avec un jeton retiré du fichier factice, `config` échoue et sa sortie contient le nom de la variable (`GH_RUNNER_TOKEN_MORIA`).
- [ ] **Step 2: Lancer** `TEST_ONLY=unit` n'exécute pas cette section : `make test` → FAIL (fichier compose absent).
- [ ] **Step 3: Écrire `scripts/lib/runners.sh`** avec les trois éléments ci-dessus (`runner_token_var` met en majuscules).
- [ ] **Step 4: Écrire `docker-compose.runners.yml`** : `name: runners`, bloc `x-runner: &runner` (image, restart, `EPHEMERAL`, `RUNNER_SCOPE`), cinq services qui fusionnent l'ancre et ajoutent `REPO_URL`, `RUNNER_NAME`, `LABELS`, `ACCESS_TOKEN: ${GH_RUNNER_TOKEN_<NOM>:?Set GH_RUNNER_TOKEN_<NOM> in .runner.env}`. Reprendre mot pour mot les commentaires utiles de `docker-compose.runner.yml` (pourquoi hors stack `infra`, pourquoi tag mouvant, pourquoi PAT hors `.env`). Services à socket : volume nommé `runner-<nom>-work:/_work` + le socket (comme l'ancien Infra). EA : le profil de la contrainte globale. Moria : `tmpfs: /_work:exec`, rien d'autre.
- [ ] **Step 5: Ajouter à `_checks` de `pr_validation.py`** une vérification `docker compose -f docker-compose.runners.yml --env-file <env factice de cinq jetons> config -q`, construite comme celle de `docker-compose.portainer.yml` (ligne ~176). Le fichier factice est écrit par la même fonction que `.env`, dans `$ws`.
- [ ] **Step 6: Lancer** `make test` → toute la section `runners compose` en `ok`.
- [ ] **Step 7: Commit** `feat(runners): one compose for the five repo runners`

### Task 2: `gen-runner-env.sh` et `runner-status.sh` multi-dépôts

**Files:**
- Modify: `scripts/gen-runner-env.sh`, `scripts/runner-status.sh`, `scripts/test.sh`

**Interfaces:**
- Consumes: `RUNNERS`, `runner_repo`, `runner_token_var` (Task 1).
- Produces: `gen-runner-env.sh [--force]` écrit `.runner.env` (mode 600) avec les cinq `GH_RUNNER_TOKEN_*` ; `runner-status.sh [--busy]` : sans option, affiche conteneurs (`docker compose -f docker-compose.runners.yml ps`) puis, par dépôt, ce que GitHub a d'enregistré ; avec `--busy`, exit 3 si **un** runner de **un** des cinq dépôts est occupé et porte son label propre.

- [ ] **Step 1: Test qui échoue** — dans `test.sh`, avec un `curl` factice en tête du `PATH` (script qui répond 200/401/404 selon l'URL) : `gen-runner-env.sh` lit cinq jetons sur stdin, un par ligne ; assertions : (a) cinq jetons valides → `.runner.env` contient cinq lignes `GH_RUNNER_TOKEN_*`, mode 600 ; (b) le jeton d'`EA` répond 404 → exit ≠ 0, sortie contenant `nicolaslallier/EA`, **aucun** fichier écrit. `runner-status.sh --busy` avec un faux GitHub où `heaven-host` est `busy:true` → exit 3 et la sortie nomme `heaven-host` ; tous libres → exit 0.
- [ ] **Step 2: Lancer** `make test` → FAIL.
- [ ] **Step 3: Adapter `gen-runner-env.sh`** : boucle sur `RUNNERS`, chaque jeton validé contre `/repos/<repo>/actions/runners` comme aujourd'hui (garder les messages 401/403/404 et en ajouter le dépôt) ; en non-interactif, cinq lignes sur stdin dans l'ordre de `RUNNERS` ; écriture seulement si les cinq passent. Conserver `--force` et l'en-tête de commentaire du fichier généré (adapté).
- [ ] **Step 4: Adapter `runner-status.sh`** : extraire `fetch_runners` en fonction paramétrée par `<name>`, boucler sur `RUNNERS`, garder la distinction `bad-credential` / `bad-scope` / `unreachable` par dépôt, et le message « aucun runner avec le label `<nom>` enregistré ». `--busy` : occupé = `.busy` et label égal au nom du runner ; tout état non `ok` reste un avertissement exit 0 comme aujourd'hui.
- [ ] **Step 5: Lancer** `make test` → ok.
- [ ] **Step 6: Commit** `feat(runners): five PATs and per-repo status`

### Task 3: Déploiement de la stack par l'API Portainer

**Files:**
- Create: `scripts/runners-stack.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: `scripts/lib/portainer-api.sh` (sourcé : fournit `api`, `$eid`), `scripts/runner-status.sh --busy` (Task 2), `daemon_dir` de `portainer-stack.sh` (à recopier à l'identique avec la mention `# ponytail: copie de portainer-stack.sh`).
- Produces: `scripts/runners-stack.sh up|down|status|delete|selftest`. `up` crée ou redéploie la stack Portainer `runners` (`RepositoryURL=https://github.com/nicolaslallier/Infra`, `RepositoryReferenceName=refs/heads/main`, `ComposeFile=docker-compose.runners.yml`, `Env` = `env_json` de `.runner.env` + `INFRA_DIR`). `env_json <env-file> <dir>` : fonction pure, ne garde que les lignes `GH_RUNNER_TOKEN_*=` et ajoute `INFRA_DIR`.

- [ ] **Step 1: Test qui échoue** — `selftest` du script (appelé par `test.sh` comme `portainer-stack.sh selftest`) : `env_json` sur un fichier contenant les cinq jetons, un commentaire, `PORTAINER_API_KEY=x` et un `INFRA_DIR=/stale` rend exactement les cinq paires + `{"name":"INFRA_DIR","value":"/repo"}` ; `daemon_dir /mnt/c/Users/nicol/OpenCode/Infra` rend `/run/desktop/mnt/host/c/Users/nicol/OpenCode/Infra`.
- [ ] **Step 2: Lancer** `make test` → FAIL (script absent).
- [ ] **Step 3: Implémenter `runners-stack.sh`** sur le modèle de `portainer-stack.sh` : `up` refuse si `.runner.env` manque ou si un des cinq jetons est vide/`change-me` (message nommant la variable), appelle `runner-status.sh --busy` sauf `FORCE=1`, puis POST (`/stacks/create/standalone/repository?endpointId=$eid`) ou PUT (`/stacks/$sid/git/redeploy?endpointId=$eid`, `RepullImageAndRedeploy` vrai pour `pull`) comme le script existant ; `INFRA_DIR` = `daemon_dir "${PORTAINER_INFRA_DIR:-$PWD}"`. `down` : `/stacks/$sid/stop`. `status` : ligne de la stack `runners` + hash de commit déployé vs `origin/main`. Pas de garde de dérive ni de synchronisation du checkout hôte : seul `certs/infra-ca.crt` (gitignoré) y est lu, et le script vérifie son existence avant `up`.
- [ ] **Step 4: Lancer** `make test` → ok.
- [ ] **Step 5: Commit** `feat(runners): deploy the runners stack through Portainer`

### Task 4: Makefile, suppression des anciens composes, documentation

**Files:**
- Modify: `Makefile`, `.env.example`, `README.md`, `AGENTS.md`, `CLAUDE.md`
- Delete: `docker-compose.runner.yml`, `docker-compose.runner-ea.yml`

**Interfaces:**
- Consumes: `runners-stack.sh`, `runner-status.sh`, `gen-runner-env.sh`.
- Produces: cibles `runners-env` (`FORCE=1`), `runners-up`, `runners-down`, `runners-pull`, `runners-restart` (= redéploiement), `runners-logs`, `runners-status`. `runners-up/-down/-pull/-restart` passent par `runners-stack.sh` (qui contrôle `--busy`). Plus aucune cible `runner-*` ni `runner-ea-*`.

- [ ] **Step 1: Test qui échoue** — dans `test.sh` : `grep -E '^runner(-ea)?-' Makefile` ne trouve rien ; `make -n runners-up` imprime un appel à `scripts/runners-stack.sh up` ; `docker-compose.runner.yml` et `docker-compose.runner-ea.yml` n'existent plus.
- [ ] **Step 2: Lancer** `make test` → FAIL.
- [ ] **Step 3: Réécrire la section `##@ CI runners` du Makefile** : supprimer les deux blocs `RUNNER_COMPOSE` / `RUNNER_EA_COMPOSE` et leurs cibles, ajouter les sept cibles. `runners-logs` : `docker compose -f docker-compose.runners.yml --env-file .runner.env logs -f` doit passer par le démon local (`DOCKER_HOST` du Makefile). Mettre à jour la ligne `.PHONY` (ligne ~16).
- [ ] **Step 4: Supprimer les deux anciens composes** (`git rm`).
- [ ] **Step 5: Documentation** — `CLAUDE.md` (section « CI: deploying on a push to main ») : cinq runners, une stack `runners`, profils de privilèges par runner (socket sur darkangel/heaven/infra seulement), règle « self-hosted jamais pour les PR », rulesets de `main`, remplacement de la note « Branch protection on main is what keeps those two sets the same size » par l'état réel ; `README.md` (tableau des cibles lignes ~565-570 et section ~896) ; `AGENTS.md` (ligne 99-104) ; `.env.example` (bloc « CI runner », lignes ~251-269 : cinq variables).
- [ ] **Step 6: Lancer** `make test` → ok.
- [ ] **Step 7: Commit** `refactor(runners): make runners-* replaces the two runner composes`

### Task 5: Check de PR d'Infra sur runner GitHub

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Produces: job `test` (nom du check requis : `test`), déclencheur `pull_request` sur `main`, `runs-on: ubuntu-latest`, `permissions: contents: read`, **sans** filtre `paths`.

- [ ] **Step 1: Écrire le workflow** : `actions/checkout@v5` avec `persist-credentials: false`, `astral-sh/setup-uv` (version exacte, vérifiée existante et vieille d'au moins deux semaines), puis `make test`. Aucune étape ne référence un secret.
- [ ] **Step 2: Vérification** — ouvrir la PR de cette branche : le check `test` doit passer sur le runner hébergé. S'il échoue parce que `make test` suppose Docker Desktop (contexte `desktop-linux`, `~/.cache`), adapter `scripts/test.sh` (repli déjà prévu sur `unix:///var/run/docker.sock`) et relancer ; sinon, restreindre le check à `TEST_ONLY=unit` et le noter dans `CLAUDE.md`.
- [ ] **Step 3: Commit** `ci: run make test on pull requests (GitHub-hosted)`

### Task 6: `github-harden.sh` — rulesets et réglages Actions

**Files:**
- Create: `scripts/github-harden.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: `scripts/lib/runners.sh` (`runner_repo`).
- Produces: `scripts/github-harden.sh [--apply] <name>` (`name` ∈ `RUNNERS`) ; sans `--apply`, imprime le ruleset et les réglages voulus et l'écart avec l'état actuel (lu par `gh api`), ne modifie rien. `ruleset_json <name> -> JSON` (fonction pure, testable). Table `CHECKS[<name>]` des checks requis : darkangel = `Backend unit + regression`, `Backend integration (real SeaweedFS + Postgres)`, `Frontend (vitest + vue-tsc + vite build)` ; ea = les noms de jobs de `ci.yml` d'EA ; heaven = `test (3.11)`, `test (3.12)`, `test (3.13)`, `image`, `image-web` ; infra = `test` ; moria = `build`, `image`, `pin`.

- [ ] **Step 1: Test qui échoue** — `ruleset_json infra` : `.name == "main-protection"`, `.enforcement == "active"`, `.bypass_actors == []`, `.conditions.ref_name.include == ["~DEFAULT_BRANCH"]`, les types de règles contiennent exactement `pull_request`, `required_status_checks`, `required_linear_history`, `deletion`, `non_fast_forward` (et ni `required_signatures`), `pull_request.required_approving_review_count == 0`, `required_status_checks.strict_required_status_checks_policy == true` et contexte `test`. Pour `darkangel`, trois contextes. `harden.sh nope` → exit ≠ 0.
- [ ] **Step 2: Lancer** `make test` → FAIL.
- [ ] **Step 3: Implémenter** : `ruleset_json` avec `jq -n`, résolution de l'id du ruleset existant par nom `main-protection` (`gh api repos/<repo>/rulesets`) pour choisir POST ou PUT ; réglages Actions : `PUT repos/<repo>/actions/permissions/fork-pr-contributor-approval` avec `approval_policy: all_external_contributors`, `PUT repos/<repo>/actions/permissions` avec `allowed_actions: selected` + `github_owned_allowed: true` + `verified_allowed: true`. Les anciens rulesets (`Main`, `Protect Main`) sont listés, jamais modifiés. **Avant l'écriture, vérifier que chaque nom de check requis existe bien dans les workflows `pull_request` du dépôt** (`gh api repos/<repo>/contents/.github/workflows/<f>`), et refuser sinon : un check inexistant bloquerait toute fusion.
- [ ] **Step 4: Lancer** `make test` → ok.
- [ ] **Step 5: Commit** `feat(security): script to harden main and Actions settings on the five repos`

### Task 7: Bascule et application (manuelle, avec accord à chaque étape)

**Files:** aucun fichier ; commandes à exécuter par le propriétaire ou avec son accord explicite.

- [ ] **Step 1:** Créer cinq PAT fine-grained (un par dépôt, `Administration: read and write`, ce dépôt seul) ; `make runners-env` (les cinq sont validés avant écriture).
- [ ] **Step 2:** Fusionner la PR de cette branche dans `main`, puis `git pull --ff-only` dans le checkout principal.
- [ ] **Step 3:** `make runners-up` depuis le checkout principal. Vérifier : `make runners-status` montre cinq runners `online` avec leur label. Les anciens runners (`infra-host`, `darkangel-host`) coexistent brièvement.
- [ ] **Step 4:** Arrêter les anciens conteneurs (projets `runner` et `runner-ea`, `docker compose -p <projet> down`) ; retirer les enregistrements périmés (`ea-host`, `MAC-EA`, anciens `infra-host`/`darkangel-host` s'ils restent) par `gh api -X DELETE repos/<repo>/actions/runners/<id>` — **sur accord explicite**.
- [ ] **Step 5:** Pousser un commit de test sur `main` d'Infra n'est plus possible une fois le ruleset appliqué : vérifier le déploiement avec `workflow_dispatch` de `deploy.yml` (le job doit être pris par `infra-host`).
- [ ] **Step 6:** `scripts/github-harden.sh <nom>` (dry-run) puis `--apply` pour darkangel, ea, heaven, moria, **infra en dernier**, un dépôt à la fois, après accord explicite pour chacun. Contrôler ensuite : `gh api repos/<repo>/rulesets` montre `main-protection` `active`.
- [ ] **Step 7:** Hors de cette branche (autres dépôts, à proposer en PR au propriétaire) : dans Heaven `deploy.yml`, ajouter à la condition `workflow_run` : `&& github.event.workflow_run.head_repository.full_name == github.repository` ; dans Moria, un workflow visant `runs-on: [self-hosted, moria]` seulement sur `push` à `main` / `workflow_dispatch`, si un déploiement ou un build LAN y est voulu.

---

## Auto-revue

- **Couverture du spec** : compose + stack Portainer (T1, T3), `make runners-*` (T4), anciens composes supprimés (T4), PAT par dépôt (T1-T2), privilèges par runner (T1), check Infra hébergé (T5), ruleset, réglages Actions, rien contourné (T6), ordre Infra en dernier et accord explicite (T7), correctif Heaven (T7), docs `CLAUDE.md` (T4), bascule (T7). Non couvert volontairement : commits signés (désactivés), sha pinning, runners de PR.
- **Cohérence** : `runner_token_var`, `RUNNERS`, `runner_repo` définis en T1 et utilisés en T2, T3, T6 ; `--busy` défini en T2, consommé en T3 ; nom du check Infra `test` identique en T5 et T6.
- **Proportion** : une section par tâche, signatures et assertions seulement.
