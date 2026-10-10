# Plan d'implémentation : service de notifications (SMTP + ntfy)

> Pour l'exécution : cocher les cases au fur et à mesure. Chaque tâche se
> termine par une vérification observable ; ne pas passer à la suivante sans
> elle.

**But :** deux services sur `infra-net`, `smtp` (relais Postfix → smarthost)
et `ntfy` (push), appelables par les applications sans logique SMTP/push
propre.

**Spec :** `docs/superpowers/specs/2026-10-10-notifications-design.md`

**Hors de ce plan :** SMS / appel (extension ultérieure), VPN, intégration
côté DarkAngel (autre dépôt), Web Push navigateur (voir Tâche 0).

## Contraintes globales

- Aucun `ports:` sur `smtp` ni `ntfy` (règle d'ingress unique, CLAUDE.md).
- Images épinglées par **tag et digest** (comme `neo4j`, `s3`), jamais `latest`.
- Chaque montage du dépôt passe par `${INFRA_DIR:-.}/…` et chaque fichier
  monté est **commité** : le garde de dérive refuse les fichiers non suivis.
- Toute nouvelle clé de `.env.example` reçoit sa règle dans
  `scripts/check-env.sh`, sans quoi une clé absente est déployée comme chaîne
  vide.
- Les identifiants (mot de passe du smarthost, jetons ntfy) ne vont jamais
  dans un commit, ni dans les journaux.
- Nginx : `resolver 127.0.0.11` + `set $upstream …` pour tout nouveau vhost.

## Piège de déploiement à lire avant tout

Une fusion sur `main` déclenche `deploy.yml`, qui redéploie toute la pile
(brève coupure DNS comprise) avec un `.env` **rendu depuis OpenBao**. Si les
nouvelles variables (`SMTP_RELAY_*`, …) ne sont pas dans le coffre à ce
moment-là, `check-env` refuse et le déploiement échoue. Donc, **avant de
fusionner** : les ajouter à `.env` puis `make vault-seed` (Tâche 7). Un PR
« docs seulement » (spec, plan) ne déploie pas ; le PR d'implémentation, si.

---

## Tâche 0 : décisions bloquantes (aucun code)

Reprendre les « Questions ouvertes » de la spec et noter les réponses en tête
de la spec (statut → « approuvé »).

- [ ] Q1 smarthost : Workspace + mot de passe d'application autorisé ? Sinon
  choisir le fournisseur transactionnel (change `SMTP_RELAY_HOST` et les
  enregistrements DNS de la Tâche 5, rien d'autre).
- [ ] Q2 relais `upstream-base-url: https://ntfy.sh` : oui/non (Tâche 2).
- [ ] Q3 VPN : confirmer qu'il est hors de ce lot.
- [ ] Q4 Web Push navigateur : v1 ou plus tard (Tâche 2, clés VAPID).
- [ ] Créer le compte `notifications@famillelallier.net` (ou alias « Envoyer
  en tant que ») et son mot de passe d'application ; le garder sous la main.

**Vérifier :** la spec ne contient plus de question sans réponse.

## Tâche 1 : service `smtp`

**Fichiers :** `docker-compose.yml`, `.env.example`, `scripts/check-env.sh`

- [ ] Lire d'abord un service voisin de même forme (`rabbitmq`) et
  `scripts/check-env.sh` (comment une clé obligatoire est déclarée).
- [ ] Choisir l'image (candidate `boky/postfix`), relever tag + digest ;
  vérifier dans sa doc les noms de variables (`RELAYHOST`,
  `RELAYHOST_USERNAME`, `RELAYHOST_PASSWORD`, `ALLOWED_SENDER_DOMAINS`) et le
  réglage `mynetworks` : relais accepté **seulement** depuis `infra-net`.
- [ ] Ajouter le service : `restart: unless-stopped`, réseau `infra-net`
  (alias `smtp`), volume nommé `smtp-spool` déclaré en bas du fichier, pas de
  `ports:`, healthcheck sur `:25`.
  Variables : `RELAYHOST: ${SMTP_RELAY_HOST:?…}`,
  `RELAYHOST_USERNAME: ${SMTP_RELAY_USERNAME:?…}`,
  `RELAYHOST_PASSWORD: ${SMTP_RELAY_PASSWORD:?…}`,
  `ALLOWED_SENDER_DOMAINS: ${SMTP_ALLOWED_SENDER_DOMAINS:-famillelallier.net}`.
- [ ] `.env.example` : les quatre clés, avec commentaire (pourquoi un
  smarthost, où créer le mot de passe d'application).
- [ ] `check-env.sh` : clés requises ; refuser vide et `change-me` pour
  `SMTP_RELAY_PASSWORD`.
- [ ] Tester le relais seul sur la machine de dev : `docker compose config`
  puis `docker compose up -d smtp`.

**Vérifier :**
- `docker compose config` sans erreur ; `docker compose ps smtp` → healthy.
- Depuis un conteneur jetable de `infra-net` (`swaks` ou `msmtp`) : un envoi
  vers l'adresse de l'utilisateur est accepté par `smtp:25` et ressort chez le
  smarthost (`docker compose logs smtp` → `status=sent`).
- Depuis l'hôte, `nc -z 127.0.0.1 25` échoue (rien de publié).

## Tâche 2 : service `ntfy`

**Fichiers :** `docker-compose.yml`, `ntfy/server.yml` (nouveau, versionné),
`.env.example`

- [ ] Image `binwiederhall/ntfy` : tag + digest ; commande `serve`.
- [ ] `ntfy/server.yml` : `base-url`, `behind-proxy: true`,
  `listen-http: ":80"`, `cache-file`, `auth-file`,
  `auth-default-access: deny-all`, `enable-metrics: true` ; selon Tâche 0 :
  `upstream-base-url`, clés `web-push-*` (générées avec `ntfy webpush keys`,
  clé privée **hors** du dépôt, passée par variable d'environnement
  `NTFY_WEB_PUSH_PRIVATE_KEY` + `.env.example`).
- [ ] Service : volume `ntfy-data` (`/var/lib/ntfy`), montage en lecture seule
  `${INFRA_DIR:-.}/ntfy/server.yml:/etc/ntfy/server.yml:ro`, alias `ntfy`,
  `restart: unless-stopped`, healthcheck `wget -qO- http://localhost/v1/health`.
- [ ] `git add ntfy/server.yml` (garde de dérive).

**Vérifier :**
- `docker compose up -d ntfy` → healthy.
- `curl http://ntfy/test` depuis `infra-net` sans jeton → **401/403** (et non 200).
- `docker compose restart ntfy` : la base d'authentification survit (Tâche 4
  la remplit).

## Tâche 3 : NGINX et Prometheus

**Fichiers :** `nginx/conf.d/ntfy.conf`, `monitoring/prometheus/prometheus.yml`

- [ ] `ntfy.conf` sur le modèle de `rabbitmq.conf` : `server_name
  ntfy.infra.famillelallier.net`, `proxy_pass` via `$upstream`, WebSocket
  (`Upgrade`/`Connection`), `proxy_read_timeout`/`proxy_send_timeout` longs,
  `proxy_buffering off`, pas d'oauth2-proxy. Relire
  `nginx/snippets/proxy.conf` pour ne pas dupliquer ses en-têtes.
- [ ] Job `ntfy` dans `prometheus.yml` (`ntfy:80`, chemin `/metrics`) après
  le job `rabbitmq`.
- [ ] Valider : `docker compose exec nginx nginx -t` ;
  `promtool check config` (image `prom/prometheus`, comme le fait
  `pr_validation.py`).

**Vérifier :**
- `curl --cacert certs/infra-ca.crt https://ntfy.infra.famillelallier.net/v1/health`
  → `{"healthy":true}`.
- Prometheus : cible `ntfy` à `up`.
- Un flux ouvert (`curl -N …/<sujet>/json` avec jeton) reste ouvert plus de 60 s.

## Tâche 4 : provisionnement des jetons

**Fichiers :** `scripts/provision-ntfy.sh`, `Makefile`

- [ ] Script sur le modèle de `scripts/provision-s3.sh` (validation stricte du
  nom d'app par regex, jamais d'interpolation brute dans une commande) :
  `scripts/provision-ntfy.sh <app> [préfixe-de-sujet]`.
  Dans le conteneur : `ntfy user add` (si absent) ; `ntfy access <app>
  '<préfixe>-*' write-only` ; `ntfy token add <app>`. Idempotent : ne pas
  recréer un utilisateur existant ; afficher le jeton **une fois** sur stdout.
  Mot de passe de l'utilisateur d'application : aléatoire, jamais affiché.
- [ ] Cible `ntfy-provision` (`check-env` en prérequis, `app=` obligatoire,
  `.PHONY`, entrée `## …` pour `make help`), calquée sur `s3-provision`.
- [ ] Utilisateur humain : documenter `docker compose exec ntfy ntfy user add
  <nom>` + `ntfy access <nom> '*' read-only` (mot de passe saisi, jamais
  dans le dépôt) ; décider s'il vaut une cible `ntfy-user`.

**Vérifier :**
- `make ntfy-provision app=darkangel` affiche `tk_…`.
- `curl -H "Authorization: Bearer tk_…" -d test http://ntfy/darkangel-echeances` → 200.
- Même requête sur `http://ntfy/autre-sujet` → 403 ; même requête sans jeton → 401.
- Relancer la cible ne casse pas le jeton existant.

## Tâche 5 : délivrabilité (hors dépôt)

- [ ] Registraire / DNS public de `famillelallier.net` (pas Technitium) :
  SPF contenant `include:_spf.google.com` ; DKIM activé dans la console
  Workspace (`google._domainkey`) ; DMARC `_dmarc` en `p=none` avec adresse
  de rapport.
- [ ] Envoyer un message de test par `smtp:25` vers une boîte Gmail
  personnelle et vers une autre (Outlook) ; ouvrir « afficher l'original ».

**Vérifier :** `spf=pass`, `dkim=pass`, `dmarc=pass`, message en boîte de
réception. Resserrer DMARC (`quarantine`) plus tard, pas dans ce lot.

## Tâche 6 : téléphone

- [ ] Installer l'app ntfy ; serveur `https://ntfy.infra.famillelallier.net`
  (la CA de la stack doit être de confiance sur le téléphone, comme pour
  les autres vhosts) ; se connecter avec l'utilisateur humain ; s'abonner à
  `darkangel-*` ou à un sujet de test.
- [ ] Si `upstream-base-url` est activé : vérifier qu'iOS reçoit bien
  instantanément écran verrouillé ; sinon, noter la limite dans le README.

**Vérifier :** `POST` depuis un conteneur de `infra-net` → la notification
s'affiche sur le téléphone, sur le Wi-Fi maison.

## Tâche 7 : secrets et déploiement

- [ ] Ajouter les nouvelles clés au `.env` local, puis `make vault-seed`.
- [ ] `make check-env` passe sur le `.env` rendu ; le PR n'est fusionné
  qu'après cela (voir « Piège de déploiement »).
- [ ] Vérifier que les valeurs nouvelles figurent bien dans `infra/env`
  (`make vault-env` ne les rapporte pas comme manquantes).
- [ ] Après fusion : suivre le déploiement `deploy.yml` ; surveiller
  `docker compose ps` ; relancer la vérification de la Tâche 6.

**Vérifier :** déploiement vert ; `smtp` et `ntfy` healthy ; les
comptes/jetons ntfy et la file Postfix survivent à ce redéploiement
(`make up` recrée tout).

## Tâche 8 : documentation

**Fichiers :** `README.md`, `CLAUDE.md`

- [ ] `README.md`, nouvelle section « Notifications » avant « Connecting an
  application repo » : adresses internes (`smtp:25`, `http://ntfy`), tableau des
  variables à donner aux applications (`SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`,
  `SMTP_TLS`, `NTFY_URL`, `NTFY_TOKEN`, `NTFY_TOPIC`), procédure
  `make ntfy-provision`, installation sur téléphone, SPF/DKIM/DMARC, limites
  (pas d'accès hors LAN sans VPN, quota du smarthost).
- [ ] `CLAUDE.md` : puces `smtp` et `ntfy` dans « Architecture » (pourquoi un
  smarthost, `deny-all`, vhost sans oauth2-proxy), les deux dans la liste
  « Do not add a `ports:` entry… », mention dans « Single-ingress rule ».
- [ ] `.env.example` relu : chaque clé commentée.

**Vérifier :** relecture croisée avec le tableau de la spec ; aucune
variable documentée qui n'existe pas dans `.env.example`.

## Recette finale (critères d'acceptation)

- [ ] SMTP : envoi depuis `infra-net` → arrivé en boîte de réception, SPF/DKIM ok.
- [ ] Push : `POST` avec jeton → notification sur le téléphone ; sans jeton → refus.
- [ ] `make up` puis `docker compose restart smtp ntfy` : tout repart, rien perdu.
- [ ] README documente variables et adresses internes de chaque service.

## Ordre et découpage en PR

1. PR docs (spec + ce plan) : déjà ouverte, ne déploie pas.
2. PR implémentation (Tâches 1 à 4, 8) : **à ne fusionner qu'après la Tâche 7**.
   Tâches 5 et 6 sont manuelles et se font pendant que le PR est en revue.

## Extension envisagée (hors lot)

SMS ou appel d'urgence : option 1 (passerelle courriel opérateur, via `smtp`),
option 2 (`X-Call` de ntfy avec Twilio) ou service `sms` dédié — voir
la discussion dans la conversation ; à rouvrir si le VPN n'est pas livré.
