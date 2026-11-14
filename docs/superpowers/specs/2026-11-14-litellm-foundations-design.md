# LiteLLM : fondations (modèles cloud, teams, utilisateurs, clés, budgets)

Chantier 1 sur 4 de la mise en place de LiteLLM en passerelle multi-usagers.
Les suivants, brainstormés chacun à son tour : (2) policies et guardrails par
team, (3) MCP et tools (Obsidian, GitHub, Portainer), (4) agents, skills,
mémoire.

## Intention

LiteLLM (`litellm/config.yaml`, image `v1.83.14-stable`) sert aujourd'hui des
modèles Ollama locaux, un vector store et des guardrails PII, derrière une
seule clé maître. Nicolas veut en faire la passerelle de tous : lui, sa
famille, les applications de la maison (Jarvis, DarkAngel, EA, le projet AI)
et les sessions dev (`devbox`). Il veut aussi pouvoir appeler Anthropic,
Gemini et OpenAI, **sans jamais dépenser plus de 200 $ CAN par mois, tous
fournisseurs confondus**, et savoir qui consomme quoi.

## Buts

- Modèles cloud (Anthropic, Gemini, OpenAI) disponibles via LiteLLM, derrière
  des clés virtuelles, jamais avec les clés des fournisseurs.
- Quatre teams, des utilisateurs internes, des clés par usage.
- Un plafond global de 200 $ CAN par mois, remis à zéro tous les 30 jours, et
  des plafonds par team qui le répartissent.
- Toute la structure (teams, utilisateurs, plafonds, clés) déclarée dans un
  fichier versionné, appliquée par un script idempotent, reconstructible
  après la perte de la base.

## Non-buts

- Policies fines, guardrails par team, serveurs MCP, agents, skills, mémoire :
  chantiers 2 à 4. Ce chantier ne touche ni `guardrails:` ni `mcp_servers:`.
- Limites de débit (rpm/tpm) pour protéger le Mac Studio : pas demandé.
- Branchement de `devbox create` sur ce script : plus tard.
- SSO Keycloak sur l'interface LiteLLM.

## Anti-buts (l'échec même si ça marche)

- Un prompt qui part chez un fournisseur cloud sans être passé par
  `pii-identifiants` (Loi 25).
- Une clé de fournisseur ou une clé virtuelle dans le dépôt, dans `config.yaml`
  ou dans un log.
- Un dépassement du plafond parce qu'un budget en USD a été lu comme du CAD, ou
  parce que seule la team a un plafond et pas le global.
- Une équipe (une session dev qui boucle) qui consomme le budget d'une autre.

## Contraintes

- **Les modèles locaux coûtent 0 $** dans LiteLLM : les budgets ne mordent que
  sur le cloud. Ne pas leur inventer de prix.
- **LiteLLM compte en USD.** Les plafonds sont écrits en CAD dans le fichier
  déclaratif, avec un seul facteur de conversion `cad_to_usd` en en-tête (à
  revoir de temps en temps), et le script convertit.
- Teams, utilisateurs, clés et budgets vivent en base (Postgres `litellm`),
  pas dans `config.yaml`. Le plafond global, lui, est dans
  `litellm_settings` (`max_budget`, `budget_duration: 30d`).
- Les clés des fournisseurs (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
  `OPENAI_API_KEY`) suivent la règle de `.env` : clés plates, dans le vault
  (`infra/env`), ajoutées à `.env.example`, lues dans `config.yaml` par
  `os.environ/NAME`. `check-env` les exige non vides et non `change-me`.
- Ne jamais changer `LITELLM_SALT_KEY` : les modèles stockés en base
  deviendraient illisibles.
- Une clé virtuelle n'est affichée qu'une fois, comme les tokens ntfy
  (`scripts/provision-ntfy.sh`) : le script l'imprime sur stdout, le reste sur
  stderr, et ne remplace pas une clé qui existe déjà.
- Le déploiement suit le dépôt : merge, puis `make up stack=platform` pour
  recharger `config.yaml`. Le script d'administration tourne contre l'API
  (`litellm.infra.famillelallier.net` ou `litellm:4000` sur `infra-net`) avec la
  clé maître, lue comme les autres scripts lisent leurs secrets.

## Approches considérées

- **A. Tout dans l'interface `/ui`.** Rapide, mais rien n'est versionné ni
  relisable, et une base neuve perd tout. Écartée.
- **B. Fichier déclaratif + script idempotent** (`litellm/teams.yaml`,
  `make litellm-provision`), appelant `/team/new`, `/user/new`,
  `/key/generate`. Même schéma que `provision-app`, `s3-provision`,
  `ntfy-provision`. **Choisie par Nicolas.**
- **C. Provider Terraform de LiteLLM.** Un outil et un état que le dépôt n'a
  nulle part ailleurs ; disproportionné. Écartée.

## Décisions de Nicolas

- Approche B.
- Plafond de 200 $ CAN par mois, total pour les trois fournisseurs.
- Répartition : dev et apps 70 % (140 $ CAN), famille 15 % (30 $ CAN),
  réserve 15 % (30 $ CAN) ; voir plus bas pour la forme que prend la réserve.
- Premiers MCP voulus (chantier 3) : Obsidian, GitHub, Portainer.

## Décisions de conception (mes choix, à corriger)

- **Quatre teams :** `admin`, `famille`, `apps`, `dev-sessions`.
- **La réserve est la team `admin`**, plafonnée à 30 $ CAN. Les quatre plafonds
  somment à 200 $ CAN, comme le plafond global : une clé admin qui boucle ne
  peut pas vider le budget des autres (le relecteur a relevé que sans plafond
  propre elle le pouvait).
- **Une seule source pour le plafond global : `teams.yaml`.** `config.yaml` est
  statique et ne peut pas le lire ; `litellm_settings.max_budget` y est écrit
  en USD, avec un commentaire, et un test de `make test` échoue si ce nombre
  n'égale pas `global_budget_cad × cad_to_usd` du fichier déclaratif.
- **Une relance met à jour.** Pour un objet existant (reconnu par alias), le
  script pousse les plafonds, modèles et rattachements du fichier
  (`/team/update`, `/user/update`) : une modification faite dans l'interface
  est écrasée. Il signale, sans les supprimer, les teams, utilisateurs et clés
  présents en base mais absents du fichier. Une clé existante n'est jamais
  remplacée ; `--rotate <alias>` en émet une nouvelle (même règle qu'ntfy).
- **Clés et perte de la base.** La sauvegarde nocturne (`pg_dumpall`) contient
  les clés : une restauration les retrouve. Sur une base vierge, le script
  émet de nouvelles clés et le propriétaire les redistribue ; on n'accepte pas
  de valeurs de clés imposées depuis le vault dans ce chantier.
- **Hors périmètre : la bascule des clients.** Ce chantier crée les clés ;
  passer Jarvis, DarkAngel, EA, AI et `devbox` de la clé maître à leur clé est
  fait ensuite, par le propriétaire.
- **Utilisateurs sans interface.** L'interface n'a qu'un mot de passe partagé :
  les membres de la famille n'y ouvrent pas de session. Le script crée leurs
  utilisateurs sans invitation ni clé automatique ; la clé personnelle n'a pas
  de plafond propre, seul celui de la team compte.
- **Listes `models:` par alias seulement**, sans joker, et chaque liste inclut
  `qwen3-embedding:0.6b` : le filtre MCP et `second-brain` en dépendent.
- **`apps` et `dev-sessions` se partagent les 140 $ CAN** : 70 $ CAN chacune au
  départ, pour qu'une session dev ne prive pas Jarvis.
- **Le cloud est opt-in par team** : chaque team a une liste `models:` ; seule
  `admin` voit tout. Les modèles locaux sont dans toutes les listes.
- **Alias de modèles cloud** dans `model_list`, un par fournisseur au départ
  (un modèle de milieu de gamme chacun). Pas de fallback automatique du local
  vers le cloud dans ce chantier.
- **`pii-identifiants` reste actif pour toutes les clés**, y compris celles du
  cloud ; aucune clé du fichier ne l'écarte (`opted_out_global_guardrails`) tant
  que le chantier 2 n'a pas décidé autrement.
- **Format de `litellm/teams.yaml` :** en-tête `cad_to_usd`, `global_budget_cad`,
  puis les teams (alias, plafond CAD, modèles autorisés), les utilisateurs
  (courriel, rôle `internal_user`, team) et les clés (alias, team, utilisateur
  éventuel). Une clé n'a pas de plafond propre sauf indication.

## Laissé à l'implémenteur

- Le taux `cad_to_usd` du jour (à confirmer par Nicolas à la livraison).
- Les modèles cloud précis, la liste des utilisateurs et des clés initiales
  (au minimum une clé par app connue et une par membre de la famille).
- Test des plafonds : au niveau unitaire (calcul du script et accord entre
  `teams.yaml` et `config.yaml`) ; `make test` n'a pas de pile vivante.
  `pii-identifiants` est déjà `default_on: true` dans `config.yaml` : il
  s'applique à toute clé, le script n'a rien à lui attacher.
- Vérifier dans la doc de la version épinglée que les champs utilisés
  existent bien (`max_budget`/`budget_duration` global, `models` par team,
  `/team/new`, `/user/new`, `/key/generate`). Un plafond par fournisseur
  (`provider_budget_config`) est optionnel ; à ajouter seulement si la version
  le supporte.
- Langage du script (shell + `curl` + `jq`, comme les autres), idempotence
  (reconnaître l'existant par alias), et test : au minimum un cas qui échoue
  si un plafond est écrit sans conversion.
- Documentation : la ligne `litellm` de `CLAUDE.md` et le README.
