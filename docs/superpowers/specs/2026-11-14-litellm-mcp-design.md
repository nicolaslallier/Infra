# LiteLLM : outils MCP (Obsidian en lecture, GitHub au niveau « proposer »)

Chantier 3 sur 4 (après `…-foundations-design.md` #167 et `…-cloud-pii-design.md`
#168, tous deux fusionnés). Reste : (4) agents, skills, mémoire.

## Intention

Nicolas veut qu'un agent ou Claude Code, passant par LiteLLM, puisse **lire ses
notes Obsidian** et **gérer ses dépôts GitHub**. « Gérer » est borné au
**niveau 2 : l'agent propose, Nicolas fusionne** — issues, branches, commits,
pull requests ; jamais de fusion. La raison : fusionner dans `main` d'`Infra` ou
d'`AI` fait tourner du code sur l'hôte par les runners auto-hébergés
(`CLAUDE.md`, « CI »), donc un agent qui fusionne a un accès root à l'hôte.

## Buts

- Un serveur MCP **Obsidian en lecture seule** sur le coffre (bucket S3
  `obsidian`) : lister, lire une note par chemin, chercher du texte.
- Un serveur MCP **GitHub** limité aux outils du niveau 2, sans `merge_pull_request`
  ni aucun outil qui pousse du code exécuté par un runner ou qui détruit.
- Les deux enregistrés dans LiteLLM (`mcp_servers:`), accessibles par team :
  Obsidian pour `admin` et `apps`, GitHub pour `admin` seulement.
- Les appels d'outils MCP ne sont plus refusés par la porte `cloud_pii` du
  chantier 2 (qui les refuserait aujourd'hui : pas de champ `model`).

## Non-buts

- Portainer (MCP root sur le daemon) : plus tard, si Nicolas le redemande.
- Écrire dans Obsidian, lire les pièces jointes ou les images du coffre.
- Exposer un MCP à Internet ou par un vhost NGINX ; OAuth par utilisateur.
- Masquer les **arguments** des appels d'outils (c'est l'action de Nicolas, par
  exemple le texte d'une issue). Les **résultats** qui reviennent à un modèle
  cloud restent masqués par la porte du chantier 2 (`tool_result`).
- Coût par appel d'outil, tableaux de bord, rotation automatique des tokens.

## Anti-buts (l'échec même si ça marche)

- Un agent qui fusionne une PR, par n'importe quel chemin (liste d'outils du
  serveur, de LiteLLM, ou un token qui le permet sur un dépôt sans protection).
- Un serveur MCP joignable sans secret par un autre conteneur de `infra-net`
  (LibreChat, Jarvis, EA… partagent ce réseau).
- Un accès en écriture au coffre, ou une lecture hors du bucket `obsidian`.
- Une team lisant Obsidian ou GitHub sans y avoir droit, ou l'inverse : la porte
  qui bloque tous les outils.
- Un token GitHub avec `Administration` ou `Workflows` (il permettrait de lever
  une protection ou de modifier la CI).

## Contraintes

- Chaque image est épinglée `tag@sha256`, aucun `ports:` hôte, rien dans NGINX
  (règle d'entrée unique du dépôt) ; les serveurs ne sont joints que par LiteLLM
  sur `infra-net`.
- Une **pile à part** `mcp` (`docker-compose.mcp.yml`, ligne dans `stacks.conf`),
  pour qu'un redéploiement de `platform` ne coupe pas les outils. Pas de
  `depends_on` entre piles : l'ordre de déploiement et la tolérance de LiteLLM à
  un serveur MCP absent remplacent le `depends_on`.
- Secrets : clés plates dans `.env` (vault), listées dans `.env.example` et
  exigées par `check-env`, jamais dans le dépôt ni dans un journal.
- Le serveur GitHub officiel (`github/github-mcp-server`) sait servir en HTTP
  (sous-commande `http`), reçoit le token par requête (en-tête `Authorization`)
  et accepte `--tools a,b,c` qui ne charge que ces outils et **refuse de démarrer
  sur un nom inconnu**. LiteLLM envoie le token avec `auth_type: bearer_token`.
- `make test` n'a pas de pile vivante ni de réseau : les tests du serveur
  Obsidian tournent contre un faux S3 local.

## Approches considérées

- **Obsidian — O1 : petit serveur MCP maison sur S3** (lecture seule par
  construction). **Choisie.** O2 : serveur « filesystem » communautaire sur une
  copie synchronisée (job de synchronisation, copie périmée, code non maîtrisé).
  O3 : seulement `second-brain` (ne lit pas par chemin, dépend de l'indexation).
- **GitHub — G1 : serveur officiel en conteneur épinglé.** **Choisie.** G2 :
  serveur distant hébergé par GitHub (version non épinglée, liste d'outils
  mouvante).
- **Où : pile `mcp` à part.** Choisie (contre : dans `platform`).

## Décisions de Nicolas

- Lire ses notes Obsidian et gérer ses dépôts GitHub ; Portainer laissé de côté.
- Niveau 2 pour GitHub : il fusionne lui-même.
- O1, G1, pile à part.
- **Obsidian est lisible par toute l'équipe `apps`** (les clés `jarvis`,
  `darkangel`, `ea` et `ai`), plus `admin` ; l'accès se décide par team, pas par
  clé.

## Décisions de conception (mes choix, à corriger)

- **Qui a quoi :** Obsidian pour `admin` et toute l'équipe `apps` ; GitHub pour `admin`. Les
  sessions dev ont déjà leur propre token GitHub ; `famille` n'a aucun outil. Une
  clé sans team n'a aucun outil MCP (échec fermé), clé maître comprise.
- **Où tourne la pile :** sur le homelab (colonne environnement `-` de
  `stacks.conf`), à côté de LiteLLM. Le serveur Obsidian joint S3 par l'alias
  `http://s3:8333` de NGINX. Son code vit dans `mcp/obsidian/` de ce dépôt, son
  image est construite sur place (`make app-images`, `pull_policy: never`) avec
  des dépendances épinglées, et ses tests tournent dans `make test`.
- **Les dépôts du token GitHub :** seulement ceux qui ont un ruleset actif
  aujourd'hui — `Infra`, `Jarvis`, `Moria`, `Glee`. `AI`, `EA`, `DarkAngel` et
  `Heaven` (runners auto-hébergés, sans ruleset) restent exclus tant qu'ils ne sont
  pas protégés ; les dépôts privés (`obsidian-maison`, `Final`…) ne peuvent pas
  avoir de ruleset avec ce plan GitHub et restent exclus. Le choix des dépôts est
  celui de Nicolas quand il crée le token ; le README donne la commande qui liste
  les rulesets actifs.
- **Garde-fou en plus, dans la porte :** un appel à `create_or_update_file` ou
  `push_files` sans `branch`, ou vers `main` ou `master`, est refusé. Il ne couvre
  pas une branche par défaut au nom inhabituel : c'est le ruleset qui la protège.
- **La clé maître n'a aucun outil MCP** (pas de team, échec fermé) : le test
  d'outils de l'interface d'administration ne fonctionne donc pas ; on teste avec
  la clé `nicolas-admin` de la team `admin` (README).
- **Si la porte ne voit pas les appels MCP** pendant la vérification sur proxy
  vivant (le code de LiteLLM 1.83.14 indique qu'elle les voit : ils passent par
  les callbacks de pré-appel avec le type `call_mcp_tool`), l'implémenteur
  s'arrête et le signale ; il ne bascule pas en silence sur un autre contrôle.
- **Lister les notes :** versions courantes seulement (un `ListObjectsV2`, pas les
  marqueurs de suppression) ; les copies de conflit de Remotely Save restent
  visibles.
- **Les trois secrets sont obligatoires** (`GITHUB_MCP_TOKEN`, `OBSIDIAN_MCP_TOKEN`
  et le secret de l'identité S3 en lecture seule), comme les clés de fournisseurs
  du chantier 1 : `check-env` les exige. Nicolas les met dans le vault **avant de
  fusionner**, sinon le déploiement automatique échoue ; le README donne
  l'ordre.
- **L'accès est appliqué par la porte `cloud_pii`** (qui a déjà la `team_id`
  authentifiée), indépendamment de ce que LiteLLM permet sans licence. Une
  politique versionnée dit quelle team peut appeler quel serveur ; `make test`
  vérifie qu'elle est cohérente avec `teams.yaml` et avec les `mcp_servers:` de
  `config.yaml`. Si l'édition OSS accepte les droits MCP par team
  (`object_permission`), `make litellm-provision` les pose aussi, pour que la liste
  d'outils d'une team ne montre que les siens ; ce n'est pas la source de vérité.
- **La porte laisse passer `call_mcp_tool`** (et la liste des outils) : ni
  masquage des arguments, ni règle de modèle, seulement le contrôle d'accès par
  team ci-dessus.
- **Obsidian, outils :** `list_notes(prefix, limit)`, `read_note(path)`,
  `search_notes(query, prefix, limit)`. Seulement les fichiers `.md`, jamais sous
  `.obsidian/` ; chemin normalisé (pas de `..`, pas de `/` initial) ; lecture
  bornée à 1 Mio ; recherche bornée (nombre d'objets parcourus, nombre de
  résultats, extrait court). Réponses en texte, une note à la fois.
- **Obsidian, secrets :** une identité S3 **en lecture seule** (`Read,List`) sur le
  bucket `obsidian`, distincte de celles de Remotely Save et de Prefect ; un
  secret partagé `OBSIDIAN_MCP_TOKEN` que le serveur exige (LiteLLM l'envoie en
  `bearer_token`).
- **GitHub, token :** fine-grained, **dépôts choisis** seulement (ceux qui ont le
  ruleset `main-protection`), permissions `Contents`, `Issues`, `Pull requests` en
  écriture et `Metadata` en lecture ; **jamais** `Administration`, `Workflows` ni
  `Actions` en écriture.
- **GitHub, outils :** une **liste blanche** (pas une liste noire), posée deux
  fois : `--tools` du serveur (qui échoue au démarrage si un nom change) et
  `allowed_tools` de LiteLLM, avec un test qui échoue si les deux diffèrent ou si
  `merge_pull_request` y figure. Contenu : lecture (dépôts, fichiers, commits,
  branches, issues, PR, recherche, état de la CI et journaux) et écriture de niveau
  2 (issues et commentaires, branches, commits de fichiers, ouvrir et mettre à jour
  une PR). Exclus : fusionner, créer/supprimer/forker un dépôt, supprimer un
  fichier, lancer un workflow, rulesets et propriétés, approuver une revue,
  notifications, gists, projets, alertes de sécurité.
- **Obsidian et GitHub tournent dans la pile `mcp`**, sur `infra-net`, sans port
  publié. L'image Obsidian est construite comme les autres images locales du
  dépôt (`make app-images`, `pull_policy: never`), dépendances épinglées.

## Laissé à l'implémenteur

- Le SDK MCP et la version du serveur GitHub (épinglée par digest), le port et le
  chemin HTTP de chacun, le nom exact des outils dans la version épinglée.
- Comment LiteLLM préfixe les noms d'outils par serveur et comment la porte
  retrouve le serveur appelé (`data["name"]`, `data["server_name"]`...), le
  `call_type` exact de l'appel et de la liste des outils, et ce que LiteLLM fait
  quand un serveur MCP est arrêté au démarrage (pour l'ordre de `stacks.conf`).
- La forme et le nom du fichier de politique MCP, et l'extension de
  `scripts/provision-s3.sh` pour une identité en lecture seule.
- Les limites chiffrées de la recherche et des extraits.
- Les tests : le serveur Obsidian contre un faux S3 (chemin hors limites refusé,
  `.obsidian/` invisible, taille bornée, jeton exigé), la porte (`call_mcp_tool`
  passe pour une team autorisée, refusé pour une autre, pour une clé sans team et
  pour une clé maître), l'égalité des listes d'outils, le compose et `stacks.conf`.
- Une vérification sur proxy vivant avec un faux serveur MCP (comme celle du
  chantier 2), puis la liste de vérifications à faire par Nicolas dans le README.
- La documentation : `CLAUDE.md` (entrées `litellm` et nouvelle pile) et `README.md`.
