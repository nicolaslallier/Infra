# Service de notifications partagé (courriel + push)

Statut : brouillon 2026-10-10 — décisions à valider dans « Questions ouvertes ».
Valeurs retenues par l'implémentation : smarthost Workspace, pas de relais
`ntfy.sh`, pas de Web Push, pas de VPN.

## But

Offrir aux applications de la stack (premier consommateur : DarkAngel,
rappels d'échéance de factures) deux points d'envoi sur `infra-net`, sans
qu'aucune ait sa propre logique SMTP ou push :

- **courriel** : un relais SMTP interne, `smtp:25` ;
- **push** (téléphone / navigateur) : un serveur ntfy, `http://ntfy`, API
  `POST /<sujet>`.

Aujourd'hui rien de tel n'existe dans l'Infra. Les applications n'ont donc
qu'à connaître un hôte, un port, un expéditeur et (pour le push) un jeton.

## Décisions proposées

| Question | Proposition | Pourquoi |
|---|---|---|
| Relais SMTP : tiers ou auto-hébergé ? | **Hybride** : un Postfix local sur `infra-net` qui relaie vers un *smarthost* (voir ci-dessous) | Les applications parlent à un relais stable et sans secret ; la délivrabilité est confiée à un fournisseur dont l'IP a une réputation. Envoyer en direct vers les MX depuis une IP résidentielle : port 25 sortant souvent bloqué, pas de PTR, rejet ou spam quasi certain. |
| Smarthost | **Compte dédié du Google Workspace** (`notifications@famillelallier.net`), `smtp.gmail.com:587`, mot de passe d'application | Le domaine est déjà sur Workspace (cf. `sort-mail`) : SPF et DKIM sont déjà ceux de Google, aucun nouveau fournisseur. Repli : fournisseur transactionnel (Brevo, Mailgun, SES…) si Google refuse les mots de passe d'application. |
| Push : ntfy suffit-il ? | **Oui, ntfy** | API `POST /<sujet>` telle que demandée, apps Android/iOS, interface web, ACL par sujet, jetons, métriques Prometheus. Web Push (navigateur) est pris en charge par ntfy récent : pas besoin de Web Push maison. Gotify n'a pas d'iOS ; un Web Push maison est du code à maintenir. |
| Exposition du push | **LAN + VPN seulement, aucune exposition Internet** | Cette stack n'a aucun ingress public (DNS Technitium LAN seulement). Une surface Internet pour une notification de facture n'est pas justifiée. Conséquence : l'accès hors LAN demande un VPN, qui n'existe pas encore dans la stack (hors périmètre, voir plus bas). |
| Authentification SMTP côté applications | **Aucune**, mais le relais n'accepte que le réseau `infra-net` et n'a aucun port hôte | Même modèle de confiance que `s3`/`rabbitmq` sur `infra-net`. Le relais force `From` sur le domaine autorisé. |
| Authentification push | **`deny-all` par défaut ; un utilisateur ntfy + un jeton par application**, ACL en écriture seule sur `<app>-*` | Exigence « un jeton par application émettrice ». L'utilisateur humain a la lecture sur tout. |

## Architecture

Deux services ajoutés à `docker-compose.yml`, sur `infra-net`, `restart:
unless-stopped`, **sans `ports:`** (règle d'ingress unique, CLAUDE.md).

### `smtp` — relais Postfix

- Image candidate : `boky/postfix` (relayhost, SASL sortant, `ALLOWED_SENDER_DOMAINS`,
  OpenDKIM intégré si on change un jour de smarthost). À épingler par tag
  *et* digest à l'implémentation, comme `neo4j` et `s3`.
- Écoute sur `:25` côté `infra-net` uniquement (`mynetworks` = sous-réseau
  `infra-net`). Alias réseau `smtp`.
- Sortie : `RELAYHOST=[smtp.gmail.com]:587`, STARTTLS obligatoire,
  identifiants `SMTP_RELAY_USERNAME` / `SMTP_RELAY_PASSWORD`.
- Volume `smtp-spool` pour la file : un message en attente survit à un
  redémarrage (critère « survit à un redémarrage »).
- Healthcheck : `postfix status` ou ouverture TCP `:25`.
- Pas de vhost NGINX ni de passthrough `stream{}` : aucun humain ne parle
  SMTP depuis l'hôte.

### `ntfy` — push

- Image : `binwiederhier/ntfy` (épinglée tag + digest), commande `serve`.
- `server.yml` monté depuis `ntfy/` (`${INFRA_DIR:-.}/ntfy/server.yml`,
  fichier **versionné**, sinon le garde de dérive refuse) :
  `base-url: https://ntfy.infra.famillelallier.net`, `behind-proxy: true`,
  `auth-file`, `auth-default-access: deny-all`, `cache-file`,
  `attachment-cache-dir` (ou pièces jointes désactivées), `enable-metrics: true`,
  `web-push-*` (clés VAPID) si le Web Push navigateur est retenu.
- Volume `ntfy-data` (cache des messages + base d'authentification).
  `make clean` l'efface comme les autres volumes.
- **Livraison instantanée sur téléphone** : ntfy ne passe par FCM (Android
  Play) ni APNs (iOS) qu'en relayant via `upstream-base-url: https://ntfy.sh`
  — seul l'identifiant du message transite, jamais son contenu. Sans cela :
  Android (build F-Droid) garde une connexion ouverte et marche sans cloud ;
  iOS reçoit tard ou pas. Décision à prendre (voir Questions ouvertes).
- Healthcheck : `GET /v1/health`.

### NGINX

`nginx/conf.d/ntfy.conf`, `ntfy.infra.famillelallier.net` → `ntfy:80`, sur le
modèle de `rabbitmq.conf` (`resolver 127.0.0.11` + `set $upstream`). Points
propres à ntfy :

- en-têtes `Upgrade`/`Connection` (WebSocket) et longs `proxy_read_timeout`
  / `proxy_send_timeout` (flux `/json` et `/sse` ouverts pendant des heures) ;
- `proxy_buffering off` sur ce vhost ;
- **pas derrière oauth2-proxy** : les clients (apps, téléphones) s'authentifient
  avec jeton/Basic, un SSO navigateur casserait l'API ;
- répéter `X-Trace-Id` si le vhost pose son propre `add_header`.

Le DNS et le certificat sont déjà couverts par le joker
`*.infra.famillelallier.net` : rien à faire dans `dns-provision.sh` ni
`gen-certs.sh`. Les applications sur `infra-net` n'utilisent pas NGINX et
appellent `http://ntfy` directement ; le vhost sert aux téléphones et au
navigateur.

### Provisionnement des jetons

`make ntfy-provision app=<nom> [topic=<préfixe>]` (`scripts/provision-ntfy.sh`,
sur le modèle de `provision-s3.sh`) : crée l'utilisateur `<nom>`, lui donne
`write-only` sur `<préfixe>-*` (défaut `<nom>-*`), génère un jeton
(`ntfy token add`) et l'affiche **une seule fois**. Idempotent. Les jetons
ne vont pas dans `.env` de l'Infra : ils sont consommés par l'application, pas par
Compose (cf. `PORTAINER_API_KEY`). Emplacement recommandé :
`infra/apps/<nom>` dans OpenBao, en plus de l'`.env` de l'application.

Utilisateur humain (lecture sur `*`, pour les téléphones) :
`make ntfy-user user=<nom>` ou équivalent documenté, mot de passe saisi, non
stocké dans le dépôt.

## Contrat vu par les applications

Variables à donner à chaque application (valeurs par défaut sur `infra-net`) :

| Variable | Valeur | Rôle |
|---|---|---|
| `SMTP_HOST` | `smtp` | relais interne |
| `SMTP_PORT` | `25` | |
| `SMTP_FROM` | `notifications@famillelallier.net` | expéditeur ; doit être dans `ALLOWED_SENDER_DOMAINS` |
| `SMTP_TLS` | `none` | pas de TLS sur `infra-net` ; la sortie vers Internet est en STARTTLS côté relais |
| `SMTP_USER`, `SMTP_PASSWORD` | *(vides)* | pas d'authentification interne |
| `NTFY_URL` | `http://ntfy` | adresse interne du push |
| `NTFY_TOKEN` | `tk_…` (par application) | `Authorization: Bearer $NTFY_TOKEN` |
| `NTFY_TOPIC` | `<app>-<catégorie>` | ex. `darkangel-echeances` |

Exemple push : `curl -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: Facture Hydro-Québec"
-H "Priority: high" -d "Échéance dans 3 jours" http://ntfy/darkangel-echeances`.

Contrat de comportement (côté application, hors périmètre de l'Infra, à
documenter) : l'envoi est *au mieux* — un échec ou un délai d'attente ne doit
jamais bloquer le flux applicatif ; DarkAngel affiche déjà ses rappels dans
l'application avant tout envoi.

## Variables de l'Infra (`.env` / `.env.example`)

- `SMTP_RELAY_HOST` (`[smtp.gmail.com]:587`), `SMTP_RELAY_USERNAME`,
  `SMTP_RELAY_PASSWORD` (sans garde `:?` : un relais de notifications ne doit
  pas bloquer le déploiement de toute la stack ; `check-env` avertit s'ils sont
  vides), `SMTP_ALLOWED_SENDER_DOMAINS` (`famillelallier.net`),
  `SMTP_MYNETWORKS` (clients autorisés à relayer ; à fixer sur le sous-réseau
  d'`infra-net`).
- Pas de variable `NTFY_*` : `base-url` et `upstream-base-url` sont dans
  `ntfy/server.yml` (une variable `NTFY_*` dans l'environnement du conteneur
  serait lue par ntfy comme une surcharge de sa propre configuration).
- `check-env.sh` : les clés sont dans `.env.example` (donc exigées présentes) ;
  les valeurs vides ne produisent qu'un avertissement.
- `make vault-seed` / `vault-env` couvrent ces clés comme les autres (1:1).

## Délivrabilité (SPF / DKIM / DMARC)

Ces enregistrements vivent dans la **DNS publique** de `famillelallier.net`,
pas dans Technitium, qui n'est volontairement jamais zone `Primary` de
`famillelallier.net` (CLAUDE.md, « DNS »). Avec le smarthost Workspace :

- SPF : `include:_spf.google.com` doit déjà y être ; sinon l'ajouter.
- DKIM : activer la signature dans la console d'admin Workspace et publier
  la clé `google._domainkey`.
- DMARC : `_dmarc` en `p=none` au début, puis durcir après quelques semaines
  de rapports propres.
- L'adresse `From` est celle du compte authentifié (ou un alias « Envoyer
  en tant que » déclaré) : Google réécrit sinon l'expéditeur.

Avec un fournisseur transactionnel de repli : mêmes enregistrements, valeurs
fournies par ce fournisseur.

## Supervision

- ntfy : `enable-metrics`, nouveau job Prometheus `ntfy` (cible
  `ntfy:80/metrics`), rien de public.
- Postfix : taille de la file (`postqueue -p`) ; exportateur optionnel
  (`postfix_exporter`) et alerte « file non vide depuis > 1 h ». À décider
  si le gain justifie un conteneur de plus.
- Journaux : Alloy collecte déjà les journaux des conteneurs vers Loki ; ne
  pas journaliser les corps de messages.

## Critères d'acceptation → vérification

1. **SMTP** : depuis un conteneur de `infra-net` (ex.
   `docker run --rm --network infra-net …` avec `swaks` ou `msmtp`), envoyer à
   l'adresse de l'utilisateur ; le message arrive en boîte de réception
   (pas en indésirables) ; les en-têtes montrent `spf=pass`, `dkim=pass`.
2. **Push** : `curl` avec jeton vers `http://ntfy/<sujet>` depuis un conteneur
   de `infra-net` ; la notification apparaît sur le téléphone abonné ; la
   même requête **sans** jeton ou sur un sujet non autorisé reçoit 401/403.
3. **Redémarrage** : `make up` (qui recrée tout) puis `docker compose restart smtp
   ntfy` : les deux repartent, la file Postfix et les comptes/jetons ntfy sont
   intacts, un envoi de test passe ensuite.
4. **Documentation** : `README.md` (section « Notifications », avant
   « Connecting an application repo ») donne l'adresse interne, le tableau des
   variables ci-dessus, la procédure `ntfy-provision` et la prise en main des
   téléphones ; `CLAUDE.md` décrit `smtp` et `ntfy` dans « Architecture » et
   ajoute les deux services à la liste « Do not add a `ports:` entry… ».

Non-régression : `nginx -t` avec le nouveau vhost, `make check-env`,
`docker compose config`. Il n'y a pas de tests automatisés dans ce dépôt
pour la config (CLAUDE.md) : la validation est de lancer la pile et de dérouler
les trois scénarios ci-dessus.

## Questions ouvertes

1. **Smarthost** : Workspace avec mot de passe d'application est-il permis par
   l'administration du domaine ? Sinon, quel fournisseur transactionnel ?
2. **Livraison instantanée** : accepte-t-on `upstream-base-url: https://ntfy.sh`
   (le contenu ne transite pas, mais l'identifiant de sujet si — le hacher ou
   utiliser des noms de sujets non devinables) ? Sinon : Android F-Droid
   seulement, et iOS en interrogation.
3. **Accès hors LAN** : quel VPN (WireGuard, Tailscale) ? Aucun n'existe dans
   la stack ; c'est une fonctionnalité à part. D'ici là, les notifications
   n'arrivent sur le téléphone que sur le Wi-Fi maison.
4. **Web Push navigateur** : voulu dès la première version ? Il exige HTTPS
   de confiance sur l'appareil (CA locale déjà utilisée pour la stack) et des
   clés VAPID à générer.
5. **Postfix : qui peut envoyer ?** Tout conteneur de `infra-net` peut envoyer
   au nom du domaine. Acceptable ici (réseau de confiance) ; sinon, SASL par
   application.

## Hors périmètre

- Planification, choix du moment, contenu et gabarits des messages (chaque
  application).
- Préférences de notification par utilisateur.
- VPN / accès distant.
- Courrier entrant, boîtes aux lettres, webmail.
- Messagerie transactionnelle à grand volume (limite Workspace : ~2000
  messages/jour).

## Plan de livraison

1. Épingler les images (tag + digest), ajouter `smtp` et `ntfy`, volumes,
   `ntfy/server.yml`, `.env.example`, règles `check-env`.
2. Vhost `ntfy.conf`, job Prometheus, `make ntfy-provision`.
3. Enregistrements SPF/DKIM/DMARC chez le DNS public ; test SMTP.
4. Téléphone : installer l'app ntfy, s'abonner, test push.
5. README + CLAUDE.md, puis intégration côté DarkAngel (dépôt à part).
