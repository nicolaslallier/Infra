# Sessions de dev Claude Code en conteneur — design

Statut : brouillon à approuver. Rien n'est construit.

## Intention

Pouvoir lancer, depuis un Mac ou un PC Windows du LAN, une session de dev
isolée : un conteneur dans lequel tourne Claude Code, avec un dépôt git et
des plugins choisis, accessible en SSH à travers le NGINX d'infra. Claude
Code y travaille de bout en bout (branche, commit, PR, review, correction,
merge) sans jamais atteindre les fichiers de la machine du propriétaire ni
les services hors Portainer.

Pourquoi : garder Claude Code, avec ses droits, dans une boîte dont les
limites sont connues, tout en gardant le même environnement depuis
n'importe quelle machine, et reprendre une session le lendemain.

## Objectifs

- Un CLI Rust (Mac et Windows) : `create`, `list`, `stop`, `resume`, `delete`.
- `create` : choisir un dépôt git, choisir des plugins (catalogue public
  `claude-plugins-official` + catalogue perso), puis construire le conteneur
  avec tout déjà téléchargé et donner l'accès SSH.
- Conteneur « prêt à compiler » : Node, Python, Rust et leurs paquets de
  compilation (gcc, make, pkg-config, en-têtes openssl). Pas de Docker dedans.
- 2 à 10 sessions simultanées.
- Persistance dans SeaweedFS : le code, la mémoire/historique de Claude et
  le jeton d'abonnement. Reprise le lendemain sans perte de contexte.
- Gérées via Portainer, dans un compose dédié aux outils de dev
  (nouveau fichier, séparé de `docker-compose.yml`).
- Accès SSH unique : une passerelle derrière le NGINX d'infra, sur un seul
  port, qui route vers la bonne session selon le nom d'utilisateur.

## Non-objectifs

- Aucun accès depuis Internet : LAN seulement.
- Pas de Docker-in-Docker ni de socket Docker dans les sessions.
- Pas d'autres outils que Claude Code pour l'instant (le compose est pensé
  pour en accueillir, rien de plus n'est construit).
- Pas d'interface web.

## Anti-objectifs (un échec même si ça « marche »)

- Une session qui lit ou écrit un fichier de la machine du propriétaire.
- Une session qui atteint un site ou service du LAN hors de ce que Portainer
  gère (nginx d'infra inclus, hors passerelle SSH).
- Une clé Portainer ou une clé Docker dans un conteneur de session.
- Un jeton GitHub plus large que le seul dépôt de la session.

## Contraintes

- Le propriétaire utilise un abonnement Claude (pas de clé API). Le login se
  fait une fois dans le conteneur (lien à ouvrir dans un navigateur, code à
  coller). Le jeton est stocké dans SeaweedFS ; Claude peut le lire, c'est
  inévitable avec ce mode d'authentification.
- Les sessions n'atteignent que l'API d'Anthropic et GitHub (supposition du
  designer, confirmée dans la conversation comme besoin implicite).
- SeaweedFS est du S3 : pas de montage FUSE de `/work` (git et les
  surveillances de fichiers y sont fragiles, cf. le cas Obsidian dans
  `CLAUDE.md`). Le conteneur garde une copie de travail locale et la
  synchronise vers le bucket.
- Les ports `stream{}` de NGINX sont aujourd'hui liés à `127.0.0.1`
  (`docker-compose.yml`). Le port SSH doit être lié à `${LAN_IP}` pour être
  joignable depuis les autres machines du LAN, jamais `0.0.0.0`.
- Respect des règles du dépôt : images épinglées `tag@sha256`, pas de
  `ports:` sur les backends, `check-env`, résolution NGINX paresseuse
  (`resolver` + variable), `make test`.

## Décisions prises par le propriétaire

- Git : Claude pousse. Il crée des branches, commit, ouvre des PR, relit,
  corrige et **merge sur `main`**. Le déploiement = le merge ; le CI existant
  (runner self-hosted) fait le reste. Pas d'appel Portainer depuis une
  session.
- Le jeton GitHub est limité au seul dépôt choisi à la création.
  Conséquence assumée : le vrai garde-fou est ce jeton et la protection de
  branche, pas le conteneur, car un merge sur `main` d'un dépôt à runner
  peut exécuter du code sur l'hôte.
- Le propriétaire se connecte depuis le LAN uniquement.
- Sessions : lister, arrêter, reprendre, supprimer.

## Choix du designer (à confirmer ou corriger)

- Passerelle SSH unique plutôt qu'un port par session : NGINX ne route pas
  le TCP brut selon l'utilisateur, et 2 à 10 ports seraient pénibles.
  Authentification par clé publique du propriétaire.
- Un réseau Docker dédié aux sessions, distinct de `infra-net`, avec sortie
  limitée à Anthropic et GitHub ; la passerelle est le seul pont vers
  NGINX.
- Synchronisation vers SeaweedFS à l'arrêt de la session et à intervalle
  régulier ; un bucket, un préfixe par session. Identité S3 propre aux
  sessions (`make s3-provision`), scopée à ce bucket.
- Le CLI parle à l'API de Portainer avec une clé stockée sur la machine du
  propriétaire (même modèle que `.portainer.env`). Cette clé équivaut à
  root sur le daemon : elle reste sur la machine du propriétaire.
- Catalogue de plugins perso : un dépôt git dont l'URL est dans la
  configuration du CLI.

## Choix du designer, ajoutés après la relecture (défauts proposés, non contredits)

- Sortie réseau stricte : réseau de sessions `internal`, avec un conteneur
  proxy filtrant par nom de domaine comme seule sortie. Domaines autorisés :
  Anthropic, GitHub, crates.io, npmjs, PyPI et leurs CDN. Le critère
  d'acceptation est « seuls ces domaines sont joignables », pas seulement
  « le réseau privé est bloqué ». DNS : celui du proxy, jamais le `dns` du LAN.
- Les registres de paquets sont autorisés, sinon `cargo build`,
  `npm install` et `pip install` échouent.
- Jeton GitHub : à portée d'un seul dépôt, créé par le propriétaire et collé
  dans le CLI. Le CLI refuse un dépôt dont `main` n'a pas de protection de
  branche.
- Ressources : `mem_limit` par session et plafond de sessions actives (défaut
  4, configurable) que le CLI refuse de dépasser, car l'hôte est le laptop
  Windows (VM Docker d'environ 7,7 Go) déjà chargé par l'infra.
- Une pile Portainer par session ; la passerelle SSH dans son propre compose.
- Écouteur SSH séparé dans NGINX, lié à `${LAN_IP}` ; clés publiques du
  propriétaire dans la passerelle seulement.
- Synchronisation de `/work` et `~/.claude` vers un bucket versionné, sans
  `target/` ni `node_modules/`.
- Le CLI ne parle qu'à Portainer ; l'URL du dépôt lui est donnée.
- Image de base générique épinglée, plugins installés au démarrage ;
  utilisateur non-root, sans sudo.

## Laissé au constructeur

Format de la configuration du CLI, crates Rust, choix de l'image de base
(épinglée), mécanisme précis de sortie réseau restreinte, implémentation de
la synchronisation, nom du compose et des volumes, interface interactive
du choix de dépôt/plugins.
