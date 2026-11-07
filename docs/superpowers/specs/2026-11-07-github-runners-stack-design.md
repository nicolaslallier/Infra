# Stack Portainer unique pour les runners GitHub, et durcissement des dépôts

Date : 2026-11-07. Statut : conception, en attente d'approbation.

## Intention

Les runners GitHub self-hosted sont aujourd'hui éparpillés : un compose pour
Infra (`docker-compose.runner.yml`), un pour EA (`docker-compose.runner-ea.yml`),
et ceux de DarkAngel et Heaven vivent ailleurs ou n'existent pas (Heaven : aucun
runner enregistré alors que son `deploy.yml` en exige un ; Moria : aucun).
Le propriétaire veut **un seul fichier compose, une seule stack Portainer à
elle**, contenant un runner par dépôt : `darkangel`, `ea`, `heaven`, `infra`,
`moria` (tous sous `nicolaslallier/`, tous **publics**).

Parce que ces dépôts sont publics et qu'un runner peut détenir le socket Docker
(root sur le démon), la même livraison **sécurise les cinq dépôts**.

## Objectifs

- Un `docker-compose.runners.yml` (projet `runners`), cinq services, déployé
  comme sa propre stack Portainer. Il remplace `docker-compose.runner.yml` et
  `docker-compose.runner-ea.yml`.
- Gestion par `make runners-*` (up, down, restart, logs, status, pull, env),
  qui remplace les cibles `runner-*` et `runner-ea-*`.
- `main` des cinq dépôts protégée de façon stricte (voir plus bas).
- Aucun runner self-hosted n'est jamais atteignable depuis une PR ou un fork.

## Non-objectifs

- Pas de runners au niveau organisation (dépôts de compte personnel : impossible).
- Pas de proxy de socket Docker, pas d'autoscaling, pas de runners Mac/Windows
  (le runner `MAC-EA`, hors ligne, est simplement retiré).
- Pas d'épinglage des actions par SHA (casserait tous les workflows ; suite
  possible avec Renovate).
- Les tests et builds **de PR** ne migrent pas vers les runners self-hosted.

## Anti-objectifs (échec même si « ça marche »)

- Un job de PR ou de fork qui s'exécute sur un label self-hosted.
- Un runner recréé en plein job (la stack runners ne doit jamais être
  redéployée par `make up` de la stack `infra`, ni par un de ses propres jobs).
- Un PAT dans `.env` (il serait remis aux conteneurs et envoyé à Portainer).

## Décisions du propriétaire

- Cinq runners, un par dépôt, dans un seul compose / une seule stack Portainer.
- Les runners déploient, testent et buildent, **mais** : les tests et builds de
  PR restent sur les runners GitHub-hosted. Les runners self-hosted ne servent
  qu'après fusion dans `main` (`push`) ou en `workflow_dispatch`.
- `main` : PR obligatoire avec CI verte, suppression interdite, seul le
  propriétaire peut fusionner, protection « la plus sécuritaire possible ».
- Pour Infra, le « CI vert » est le plus sûr possible (voir mes choix).

## Mes choix (à vérifier, ce ne sont pas des décisions du propriétaire)

1. **Un PAT fine-grained par dépôt** (`Administration: read and write` sur ce
   seul dépôt), cinq variables `GH_RUNNER_TOKEN_<NOM>` dans `.runner.env`
   (gitignoré). Une fuite ne compromet qu'un dépôt côté GitHub.
2. **Privilèges par runner, pas un profil unique.** EA n'a *pas* le socket
   Docker aujourd'hui (il appelle l'API de Portainer par URL) : on garde ce
   profil. Le socket n'est monté que là où le script de déploiement lance
   `docker run` : Infra et Heaven. DarkAngel : à vérifier dans son
   `portainer-stack.sh`. Moria : aucun socket, aucun workflow self-hosted pour
   l'instant, le runner attend (un workflow devra viser le label `moria`).
3. Chaque runner : image `myoung34/github-runner:ubuntu-noble` (tag mouvant,
   voulu), `EPHEMERAL=true`, `RUNNER_SCOPE=repo`, label = nom du dépôt en
   minuscules, `restart: unless-stopped`, hors `infra-net`. Les particularités
   d'EA (`extra_hosts` vers Portainer et OpenBao, CA d'Infra, `tmpfs /_work:exec`)
   passent telles quelles dans son service.
4. **Infra** : nouveau workflow `.github/workflows/test.yml`, déclencheur
   `pull_request`, `runs-on: ubuntu-latest`, qui lance `make test`. Sans filtre
   `paths` (un check requis filtré bloque les PR qui ne le touchent pas). Il est
   à vérifier que `make test` tourne sur un runner GitHub. `pr-validation` de
   Prefect n'est pas utilisé comme check : il exécuterait le code de la PR sur
   la machine, avec le socket, avant relecture.
5. **Réglages Actions des cinq dépôts** : approbation des PR de forks =
   « tous les contributeurs externes » ; actions autorisées = celles de GitHub
   et des créateurs vérifiés ; token des workflows en lecture seule (déjà le cas).
6. **Heaven, `deploy.yml`** : le garde `workflow_run` vérifie
   `head_branch == 'main'`, qu'une PR de fork depuis une branche nommée `main`
   satisfait aussi. Ajouter `head_repository.full_name == github.repository`.
7. **Pas de branche de secours pour le propriétaire** : aucun contournement du
   ruleset (même admin). Le secours est de désactiver le ruleset à la main.

## Ruleset `main`, identique sur les cinq dépôts

Pull request obligatoire (0 approbation : GitHub interdit d'approuver sa propre
PR, le propriétaire serait bloqué), checks requis, branche à jour avant
fusion, historique linéaire, conversations résolues, suppression et force-push
interdits, liste de contournement vide. Commits signés : **non tranché**, voir
« Questions ouvertes ».

Checks requis (noms vus sur `main`, à confirmer dans les workflows) :

| Dépôt | Checks requis |
|---|---|
| DarkAngel | Backend unit + regression ; Backend integration (real SeaweedFS + Postgres) ; Frontend (vitest + vue-tsc + vite build) |
| EA | Frontend — types, lint, tests, build, et les autres jobs de `ci.yml` |
| Heaven | `test (3.11)`, `test (3.12)`, `test (3.13)`, `image`, `image-web` |
| Infra | le nouveau job de `test.yml` |
| Moria | jobs de `client.yml` et `server.yml` sur PR : à relever |

Les jobs de déploiement et de publication (`Redeploy…`, `Build and push…`) ne
sont jamais requis : ils ne tournent qu'après fusion.

## État actuel constaté (2026-11-07)

Cinq dépôts publics, propriétaire seul collaborateur (admin). `main` non
protégée partout ; rulesets d'EA (`Main`) et d'Infra (`Protect Main`)
désactivés, et ils n'interdisent que suppression et force-push. Approbation de
forks : `first_time_contributors`. Actions : `all`. Runners enregistrés :
`darkangel-host` (en ligne), `infra-host` (en ligne), `ea-host` et `MAC-EA`
(hors ligne), aucun pour Heaven et Moria. Aucun workflow n'envoie de PR vers un
label self-hosted.

## Contraintes

- **Les changements de réglages GitHub (rulesets, Actions) modifient les dépôts
  du propriétaire : ils ne s'appliquent qu'avec son accord explicite, dépôt par
  dépôt, au moment de l'application.**
- Appliquer le ruleset d'Infra en dernier : il exige un check que cette
  livraison crée, et sa propre PR doit pouvoir être fusionnée.
- Les services runners portent un `LABELS` que les `runs-on` des dépôts
  désignent ; un label renommé laisse un job en file sans erreur.
- Le compose de la stack est lu par Portainer depuis Git (comme `infra`) ;
  `.runner.env` n'est jamais envoyé comme env de stack d'`infra`.
- Mettre à jour `CLAUDE.md` (section « CI: deploying on a push to main ») : plus
  d'« un runner », et la note sur la protection de `main`.

## Laissé au constructeur

- Réutilisation ou généralisation de `scripts/portainer-stack.sh` pour une
  seconde stack (nom, fichier compose, env), et `make runners-*`.
- `scripts/gen-runner-env.sh` et `runner-status.sh` étendus aux cinq dépôts.
- Plan de bascule des runners existants (retrait de `darkangel-host`,
  `infra-host`, `ea-host`, `MAC-EA` ; où tournent aujourd'hui ceux de
  DarkAngel et Heaven).
- Noms exacts des checks requis ; application des rulesets via `gh api`.

## Précisions issues de la relecture

- **Hôte** : tous les runners tournent sur le démon de l'hôte de déploiement
  (le laptop Windows, `INFRA_HOST` 192.168.2.10), endpoint Portainer local,
  comme aujourd'hui. Les runners avec socket y ont donc root sur le démon qui
  porte toute la stack `infra` : c'est le plafond de risque accepté, d'où
  « post-fusion seulement ».
- **Socket Docker** (mon choix) : Infra, Heaven **et DarkAngel** (son
  `portainer-stack.sh` lance curl dans un conteneur jetable via `docker`).
  EA et Moria : aucun.
- **Montages depuis l'hôte** (CA d'Infra pour EA) : même mécanisme que la stack
  `infra` (`${INFRA_DIR:-.}` / `PORTAINER_INFRA_DIR`, depuis le checkout de
  l'hôte, soumis au garde-fou de dérive).
- **Env de la stack runners** : les cinq PAT viennent de `.runner.env` et sont
  envoyés à Portainer comme env de *cette* stack seulement, jamais celle
  d'`infra` et jamais via `.env`. Portainer détient donc les PAT ; il est déjà
  équivalent à root sur le démon.
- **Bascule** (mon choix) : les anciens et nouveaux runners coexistent
  brièvement (même label, le premier libre prend le job), `make runners-up`
  manuel depuis le laptop pour l'amorçage, anciens composes supprimés dans la
  même PR une fois la stack vérifiée.
- **Rulesets** : « seul le propriétaire fusionne » n'existe pas en ruleset ;
  c'est garanti par le fait qu'il est le seul collaborateur (à re-vérifier si
  quelqu'un est invité). « Branche à jour avant fusion » est retenu : chaque
  fusion peut demander un rebase.
- **`make test` sur runner GitHub** : à vérifier à la construction ; repli : un
  sous-ensemble de checks qui tourne hébergé (la validation complète reste
  possible hors check requis).
- **Moria** a des checks de PR (`build` dans `client.yml`, `image` et `pin`
  dans `server.yml`), à confirmer ; aucun workflow ne vise encore son runner.

## Questions ouvertes

- Portée : cette livraison inclut-elle des PR dans les quatre autres dépôts
  (workflow `test.yml` d'Infra, correctif `workflow_run` de Heaven) ?
- Le propriétaire signe-t-il ses commits ? (conditionne « commits signés
  obligatoires ».)
