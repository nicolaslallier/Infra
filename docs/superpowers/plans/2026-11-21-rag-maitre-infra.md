# RAG maître — plan Infra : ce que le dépôt Infra fournit au RAG

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Ce plan s'exécute dans le dépôt `nicolaslallier/Infra`**, pas dans RAG. Il est rangé ici pour voyager avec les autres ; le recopier dans `Infra/docs/superpowers/plans/2026-11-21-rag-maitre-infra.md` au début de la première PR. Partir d'`origin/main` à jour (`git fetch origin`), sur une branche, PR en brouillon ; ne jamais pousser sur `main` (un merge redéploie la production).

**Goal:** Donner au RAG maître, sans le déployer lui-même, tout ce qu'il attend de l'Infra : une base, une identité S3 en lecture seule sur le coffre, une clé LiteLLM limitée aux modèles locaux, un secret OpenBao et sa politique, un runner, puis l'entrée MCP dans LiteLLM.

**Architecture:** Comme pour le Portail : la pile `rag` appartient au dépôt RAG et n'est pas une ligne de `stacks.conf`. L'Infra ne porte que la configuration partagée (LiteLLM, OpenBao, runners, variables de `.env.example`) et la documentation des étapes manuelles. Deux PR : **A** (tâches 1 à 6, avant le premier déploiement du RAG) et **B** (tâche 7, après, quand `http://rag:8000/mcp` répond).

**Tech Stack:** celle de l'Infra : Compose, bash, Makefile, YAML, pytest par `make test`.

**Spec:** `docs/superpowers/specs/2026-11-21-rag-maitre-design.md` du dépôt RAG. À lire aussi dans l'Infra : `CLAUDE.md` (« Per-app database provisioning », « Secrets (OpenBao) », « CI: deploying on a push to main ») et la section « Portail (AI repo) » du `README.md`, qui est le modèle suivi ici.

## Contrat entre les dépôts RAG et Infra

Ce bloc est identique dans `2026-11-21-rag-maitre-0-index.md`, `…-4-deploiement.md` et `…-infra.md`. Le changer, c'est le changer aux trois endroits.

| Élément | Valeur | Fourni par |
|---|---|---|
| Réseau | `infra-net` (externe) ; aucun port publié, aucun vhost NGINX | Infra (existe) |
| Pile | Portainer `rag`, environnement local du homelab (`192.168.2.10`) ; services `rag` (API, port 8000) et `rag-indexeur` ; fichier `deploy/portainer-stack.yml` du dépôt RAG | RAG |
| Image | `ghcr.io/nicolaslallier/rag:sha-<7 car.>` (paquet privé) | RAG |
| Base | base `rag`, rôle `rag`, hôte `postgres:5432` ; mot de passe `RAG_DB_PASSWORD` (lettres et chiffres seulement) ; extension `vector` créée par `make provision-app`, `unaccent` et `pg_trgm` créées par la migration du RAG | Infra provisionne, RAG migre |
| OpenBao | secret KV v2 `infra/rag` (chemin d'API `infra/data/rag`) ; politique `rag-deploy` (lecture de ce secret seulement) ; clés : `RAG_DB_PASSWORD`, `RAG_LITELLM_CLE`, `RAG_JETON`, `RAG_JETON_PRIVE` (facultative), `RAG_JETON_REINDEXER`, `RAG_GITHUB_JETON`, `RAG_S3_SECRET_KEY`, `RAG_COFFRE_PREFIXE` (facultative) | Infra (politique), Nicolas (valeurs) |
| LiteLLM | `http://litellm:4000` ; clé d'alias `rag`, équipe `agents` (modèles locaux seulement) ; modèles utilisés : `qwen3-embedding:0.6b`, `gemma4:26b-a4b-it-qat`, `qwen3.8:27b-mlx` (juge) | Infra |
| S3 (coffre) | `http://s3:8333`, bucket `obsidian`, identité `rag` en **`Read,List`**, secret `RAG_S3_SECRET_KEY` ; préfixe du coffre `RAG_COFFRE_PREFIXE` = valeur de `ORGANIZER_VAULT_PREFIX` de l'Infra | Infra |
| GitHub (code) | `RAG_GITHUB_JETON` : jeton à portée fine, `Contents: Read` sur les dépôts `nicolaslallier/*` | Nicolas |
| MCP | LiteLLM `mcp_servers.rag` → `http://rag:8000/mcp`, `Authorization: Bearer` = `RAG_MCP_TOKEN` (même valeur que `RAG_JETON`) ; outils `rag_chercher`, `rag_lister`, `rag_repondre`, `rag_chemin`, `rag_expliquer` ; équipes `[admin]` | Infra (config), RAG (serveur) |
| Runner | `runner-rag`, label `rag`, dépôt `nicolaslallier/RAG`, `GH_RUNNER_TOKEN_RAG`, sans socket Docker | Infra |
| Env. des conteneurs | `RAG_DATABASE_URL`, `RAG_LITELLM_URL`, `RAG_LITELLM_CLE`, `RAG_JETON`, `RAG_JETON_PRIVE`, `RAG_JETON_REINDEXER`, `RAG_GITHUB_JETON`, `RAG_S3_ENDPOINT`, `RAG_S3_ACCESS_KEY`, `RAG_S3_SECRET_KEY`, `RAG_COFFRE_BUCKET`, `RAG_COFFRE_PREFIXE`, `RAG_DONNEES_DIR`, `RAG_CONFIG` | RAG |
| Niveaux de visibilité | `RAG_JETON` → `public-maison` ; `RAG_JETON_PRIVE` → `public-maison` + `prive` ; `RAG_JETON_REINDEXER` → réindexation seulement, aucune lecture | RAG |

Valeurs en double à garder égales (comme `PORTAIL_DB_PASSWORD`) : `RAG_DB_PASSWORD` et `RAG_S3_SECRET_KEY` vivent dans `infra/env` (lus par `make provision-app` et `make s3-provision`) **et** dans `infra/rag` (lus par le déploiement du RAG) ; `RAG_MCP_TOKEN` (`infra/env`, lu par LiteLLM) = `RAG_JETON` (`infra/rag`).

## Global Constraints

- Conventions de l'Infra : commentaires et documentation du dépôt en anglais, `make test` et `make check-env` verts à chaque commit, images épinglées, aucun secret dans un commit.
- La clé LiteLLM du RAG ne donne accès à **aucun modèle infonuagique** : elle est dans l'équipe `agents` (`qwen3.8:27b-mlx`, `gemma4:26b-a4b-it-qat`, `qwen3-embedding:0.6b`). C'est la garantie « rien ne sort du homelab » côté passerelle.
- L'identité S3 `rag` est **`Read,List`** sur le bucket `obsidian`, jamais `Write`.
- Le jeton OpenBao du déploiement RAG lit `infra/data/rag` et rien d'autre (jamais `infra/env`).
- `runner-rag` : pas de socket Docker, pas sur `infra-net`, comme `runner-ai`.
- Aucune étape manuelle (coffre OpenBao, Portainer, provisionnement, jetons) n'est faite par l'agent : elles sont écrites dans le README et faites par Nicolas.
- Ne pas ajouter `rag` à `stacks.conf`, ni de vhost NGINX, ni de cible Prometheus (le service n'expose pas de métriques en v1).

## Review Focus

1. **Variable ajoutée à un fichier Compose mais absente de `.env.example` / `check-env` / `ci-fake-env.sh`** : `make up` casserait pour toutes les piles. → `make check-env` et `make test` à chaque tâche, test tâche 7.
2. **Un outil MCP du RAG qui porterait le nom d'un outil existant** : la politique ne voit que le nom de l'outil, les listes doivent être disjointes. → test tâche 7.
3. **La clé `rag` placée dans une équipe qui a un modèle `cloud-*`** : → test tâche 1.
4. **LiteLLM démarre alors que `rag` n'est pas encore déployé** (serveur MCP injoignable) : c'est pourquoi la tâche 7 est une PR à part, fusionnée après le premier déploiement du RAG.
5. **Ordre des jetons de runner** : `gen-runner-env.sh` lit les jetons dans l'ordre de la table ; `rag` s'ajoute **à la fin**. → test tâche 5.

---

### Task 1: Clé LiteLLM `rag` (équipe `agents`)

**Files:**
- Modify: `litellm/teams.yaml`
- Test: `scripts/test_litellm_provision.py`

- [ ] **Step 1: Écrire le test qui échoue**

```python
def test_the_rag_key_reaches_local_models_only():
    spec = yaml.safe_load(open(os.path.join(ROOT, "litellm", "teams.yaml")))
    key = next(k for k in spec["keys"] if k["alias"] == "rag")
    models = spec["teams"][key["team"]]["models"]
    assert key["team"] == "agents" and not [m for m in models if m.startswith("cloud-")]
    assert {"qwen3-embedding:0.6b", "gemma4:26b-a4b-it-qat", "qwen3.8:27b-mlx"} <= set(models)
```

- [ ] **Step 2: Lancer** `make test` — attendu : ÉCHEC (`StopIteration`).
- [ ] **Step 3: Ajouter** à `keys:` de `litellm/teams.yaml` : `- {alias: rag, team: agents, user: null}`, et compléter le commentaire de l'équipe `agents` (« and the RAG service (RAG repo): embeddings, generation, bench judge »).
- [ ] **Step 4: Relancer** `make test` — attendu : SUCCÈS.
- [ ] **Step 5: Commit** `git commit -am "litellm: key rag in team agents (local models only)"`

---

### Task 2: Base `rag`

**Files:**
- Modify: `.env.example`, `scripts/check-env.sh`, `scripts/ci-fake-env.sh` (si la liste des bases y est reprise)

- [ ] **Step 1:** Dans `.env.example` : ajouter `rag` à la fin de `APP_DATABASES`, et sous `PORTAIL_DB_PASSWORD` une ligne `RAG_DB_PASSWORD=change-me` avec un commentaire sur le modèle de celui du Portail (« also kept in the vault secret `infra/rag`, read by the RAG repo's deploy: keep both copies equal »).
- [ ] **Step 2:** Dans `scripts/check-env.sh`, à côté de la règle `PORTAIL_DB_PASSWORD` (lettres et chiffres seulement, la valeur entre dans une URL `postgresql://`), la même règle pour `RAG_DB_PASSWORD`.
- [ ] **Step 3: Vérifier** : `scripts/ci-fake-env.sh` puis `make check-env` passent ; un `.env` d'essai avec `RAG_DB_PASSWORD=a/b` fait échouer `make check-env` avec un message qui nomme la variable.
- [ ] **Step 4: Commit** `git commit -am "postgres: rag database in APP_DATABASES, RAG_DB_PASSWORD"`

---

### Task 3: Identité S3 `rag` en lecture seule

**Files:**
- Modify: `.env.example`, `scripts/check-env.sh`

- [ ] **Step 1:** Suivre exactement ce qui est fait pour `OBSIDIAN_MCP_S3_SECRET_KEY` (`git grep -n OBSIDIAN_MCP_S3_SECRET_KEY`) : `RAG_S3_SECRET_KEY=change-me` dans `.env.example`, avec le commentaire « S3 identity `rag`, Read,List on the `obsidian` bucket (the RAG service reads the vault there): `make s3-provision app=rag bucket=obsidian actions=Read,List`. Also kept in `infra/rag`. » ; l'ajouter à la même liste de `scripts/check-env.sh`.
- [ ] **Step 2: Vérifier** `make check-env` et `make test`. Lire `scripts/provision-s3.sh` : le nom de variable attendu pour `app=rag` est bien `RAG_S3_SECRET_KEY`, et `actions=Read,List` est accepté par son expression régulière.
- [ ] **Step 3: Commit** `git commit -am "s3: read-only identity rag on the obsidian bucket"`

---

### Task 4: Politique OpenBao `rag-deploy`

**Files:**
- Create: `openbao/policies/rag-deploy.hcl`

- [ ] **Step 1: Écrire** le fichier, calqué sur `openbao/policies/portail-deploy.hcl` :

```hcl
# The RAG repo's deploy (BAO_TOKEN): its own secret, nothing else.
# renew-self / lookup-self come from the default policy.
path "infra/data/rag" { capabilities = ["read"] }
```

- [ ] **Step 2: Vérifier** : `git grep -n "portail-deploy" -- scripts Makefile .github` ; tout endroit qui énumère les politiques (sauvegarde, tests) reçoit `rag-deploy` de la même façon. `make test` vert.
- [ ] **Step 3: Commit** `git add openbao/policies/rag-deploy.hcl && git commit -m "openbao: policy rag-deploy (read infra/rag only)"`

---

### Task 5: Runner `runner-rag`

**Files:**
- Modify: `scripts/lib/runners.sh`, `docker-compose.runners.yml`, `scripts/gen-runner-env.sh`, `CLAUDE.md` (liste des runners)

- [ ] **Step 1:** `scripts/lib/runners.sh` : `RUNNERS=(darkangel:DarkAngel ea:EA heaven:Heaven infra:Infra moria:Moria ai:AI rag:RAG)` — **à la fin**.
- [ ] **Step 2:** `docker-compose.runners.yml` : un service `runner-rag`, copie de `runner-ai` (mêmes durcissements, `extra_hosts` vers Portainer et le coffre, `tmpfs`, pas de socket), avec `REPO_URL: https://github.com/nicolaslallier/RAG`, `RUNNER_NAME: rag-host`, `LABELS: rag`, `ACCESS_TOKEN: ${GH_RUNNER_TOKEN_RAG:?Set GH_RUNNER_TOKEN_RAG in .runner.env}`, et le certificat de l'Infra monté là où le workflow du RAG l'attend (`/etc/rag/infra-ca.crt` ; reprendre le montage de `runner-ai` pour `/etc/ai/infra-ca.crt`). Adapter le commentaire d'en-tête du fichier (sept runners).
- [ ] **Step 3:** `scripts/gen-runner-env.sh` : partout où six jetons sont nommés ou comptés (`GH_RUNNER_TOKEN_DARKANGEL|EA|HEAVEN|INFRA|MORIA|AI`, « All six »), passer à sept avec `RAG` en dernier.
- [ ] **Step 4: Vérifier** : `make test` ; `GH_RUNNER_TOKEN_DARKANGEL=x GH_RUNNER_TOKEN_EA=x GH_RUNNER_TOKEN_HEAVEN=x GH_RUNNER_TOKEN_INFRA=x GH_RUNNER_TOKEN_MORIA=x GH_RUNNER_TOKEN_AI=x GH_RUNNER_TOKEN_RAG=x docker compose -f docker-compose.runners.yml config -q` sort en 0 ; `bash -c '. scripts/lib/runners.sh; runner_repo rag; runner_token_var rag'` affiche `nicolaslallier/RAG` et `GH_RUNNER_TOKEN_RAG` ; le dernier élément de `RUNNERS` est `rag:RAG`.
- [ ] **Step 5: Commit** `git commit -am "runners: runner-rag for the RAG repo's deploy"`

---

### Task 6: README « RAG (RAG repo) » et PR A

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Écrire** dans `README.md`, après « Portail (AI repo) », une section « RAG (RAG repo) » : ce que c'est (deux conteneurs `rag` et `rag-indexeur` sur `infra-net`, pile Portainer du dépôt RAG, pas de vhost, pas de port), le tableau du contrat ci-dessus, puis les étapes manuelles, dans cet ordre :
  1. Base : `openssl rand -hex 24` ; `make vault-cli args="kv patch -mount=infra env RAG_DB_PASSWORD=... APP_DATABASES=<liste actuelle>,rag"` ; `make vault-env` ; `make provision-app app=rag`.
  2. S3 : `openssl rand -hex 24` ; `make vault-cli args="kv patch -mount=infra env RAG_S3_SECRET_KEY=..."` ; `make vault-env` ; `make s3-provision app=rag bucket=obsidian actions=Read,List`. Vérifier qu'une écriture avec cette identité est refusée.
  3. Clé LiteLLM : `make litellm-provision` affiche une fois la clé `rag`.
  4. Jeton GitHub du RAG : jeton à portée fine, `Contents: Read` sur les dépôts à indexer.
  5. Secret, politique et jeton du déploiement :
     ```bash
     make vault-cli args="kv put -mount=infra rag RAG_DB_PASSWORD=<étape 1> RAG_S3_SECRET_KEY=<étape 2> RAG_LITELLM_CLE=sk-... RAG_GITHUB_JETON=github_pat_... RAG_JETON=$(openssl rand -hex 32) RAG_JETON_REINDEXER=$(openssl rand -hex 32) RAG_COFFRE_PREFIXE=<valeur de ORGANIZER_VAULT_PREFIX>"
     make vault-cli args="policy write rag-deploy -" < openbao/policies/rag-deploy.hcl
     make vault-cli args="token create -policy=rag-deploy -period=768h -orphan -display-name=rag-deploy -field=token"
     ```
     Le jeton va dans le secret `BAO_TOKEN` de l'environnement `production` du dépôt RAG ; vérifier sa portée comme pour le Portail (`…/v1/infra/data/env` doit répondre 403).
  6. Runner : un jeton d'accès pour `nicolaslallier/RAG` dans `.runner.env` (`GH_RUNNER_TOKEN_RAG`), `make runners-up`, `make runners-status`.
  Puis les doubles à garder égaux (`RAG_DB_PASSWORD`, `RAG_S3_SECRET_KEY`, `RAG_MCP_TOKEN` = `RAG_JETON`) et comment tourner chacun.
- [ ] **Step 2:** `CLAUDE.md` : une phrase dans « Secrets (OpenBao) » (un second jeton à portée limitée, politique `rag-deploy`), `rag` dans la liste des runners sans socket.
- [ ] **Step 3: Vérifier** `make test`, `make check-env`, `make config` (avec l'environnement factice de la CI).
- [ ] **Step 4: Commit** `git commit -am "docs: RAG service, cross-repo contract and manual steps"` ; pousser la branche, **PR A en brouillon**. Dans la description : les étapes manuelles 1 à 6 sont à faire par Nicolas après la fusion ; `make up` échouera tant que `RAG_DB_PASSWORD` et `RAG_S3_SECRET_KEY` ne sont pas dans le coffre (même avertissement que pour le Portail).

---

### Task 7: Serveur MCP `rag` dans LiteLLM (PR B, après le premier déploiement du RAG)

Prérequis : plan 4 du RAG, tâche 6, steps 1 à 7 faits — depuis un conteneur d'`infra-net`, `curl -s -o /dev/null -w '%{http_code}' -X POST http://rag:8000/mcp` répond `401`.

**Files:**
- Modify: `litellm/config.yaml`, `litellm/mcp_policy.yaml`, `docker-compose.platform.yml`, `.env.example`, `scripts/check-env.sh`, `scripts/ci-fake-env.sh`, `README.md`
- Test: `scripts/test_mcp_policy.py`

- [ ] **Step 1: Écrire les tests qui échouent** (dans `scripts/test_mcp_policy.py`, en réutilisant ses aides `_y` et `mp`)

```python
RAG_TOOLS = ["rag_chercher", "rag_lister", "rag_repondre", "rag_chemin", "rag_expliquer"]

def test_the_rag_server_is_admin_only_with_the_agreed_tools():
    pol = _y("litellm/mcp_policy.yaml")["servers"]["rag"]
    assert pol["teams"] == ["admin"] and pol["tools"] == RAG_TOOLS

def test_the_rag_server_is_registered_in_litellm():
    s = _y("litellm/config.yaml")["mcp_servers"]["rag"]
    assert s["url"] == "http://rag:8000/mcp" and s["transport"] == "http"
    assert s["auth_type"] == "bearer_token" and s["auth_value"] == "os.environ/RAG_MCP_TOKEN" and s["allowed_tools"] == RAG_TOOLS

def test_litellm_gets_the_rag_token():
    env = _y("docker-compose.platform.yml")["services"]["litellm"]["environment"]
    assert env["RAG_MCP_TOKEN"].startswith("${RAG_MCP_TOKEN:?")
```

Les tests existants `test_tool_names_are_disjoint_across_servers` et `test_every_policy_server_is_registered_in_litellm_with_its_tools` couvrent alors le nouveau serveur ; mettre à jour `test_the_real_policy_gives_the_agreed_access` et `test_admin_reaches_both_servers` si leur attendu énumère les serveurs.

- [ ] **Step 2: Lancer** `make test` — attendu : ÉCHEC (`KeyError: 'rag'`).
- [ ] **Step 3: Implémenter.**
  - `litellm/mcp_policy.yaml`, sous `servers:` : `rag: {teams: [admin], tools: [rag_chercher, rag_lister, rag_repondre, rag_chemin, rag_expliquer]}` avec un commentaire (« the RAG service (RAG repo), read-only search over the vault and the code; reindexing is not an MCP tool »).
  - `litellm/config.yaml`, sous `mcp_servers:` : `rag:` avec `url: http://rag:8000/mcp`, `transport: http`, `auth_type: bearer_token`, `auth_value: os.environ/RAG_MCP_TOKEN`, `allow_all_keys: true`, `allowed_tools:` la même liste.
  - `docker-compose.platform.yml`, environnement de `litellm`, à côté de `OBSIDIAN_MCP_TOKEN` : `RAG_MCP_TOKEN: ${RAG_MCP_TOKEN:?Set RAG_MCP_TOKEN in .env (same value as RAG_JETON in the vault secret infra/rag)}`.
  - `.env.example` (`RAG_MCP_TOKEN=change-me`), `scripts/check-env.sh` et `scripts/ci-fake-env.sh` : comme `OBSIDIAN_MCP_TOKEN`.
  - `README.md`, section RAG : étape 7 — `make vault-cli args="kv patch -mount=infra env RAG_MCP_TOKEN=<valeur de RAG_JETON>"`, `make vault-env`, `make up stack=platform` ; puis l'essai : un appel `rag_chercher` par la passerelle MCP de LiteLLM avec la clé `nicolas-admin` rend des résultats, la même requête avec une clé de l'équipe `apps` est refusée.
- [ ] **Step 4: Relancer** `make test && make check-env` — attendu : SUCCÈS.
- [ ] **Step 5: Commit** `git commit -am "litellm: MCP server rag (admin only)"` ; **PR B en brouillon**, avec dans la description : à fusionner seulement quand `rag` répond sur `infra-net`, et après avoir mis `RAG_MCP_TOKEN` dans le coffre (sinon `make up` échoue sur le `:?`).
- [ ] **Step 6: Après la fusion par Nicolas**, vérifier dans les journaux de LiteLLM que le filtre sémantique des outils MCP s'est reconstruit sans erreur (`MCP Semantic Tool Filter enabled`, jamais `Failed to initialize`) et que les cinq outils `rag_*` apparaissent dans l'interface d'administration.
