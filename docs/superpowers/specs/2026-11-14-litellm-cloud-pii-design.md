# LiteLLM : masquage des infos personnelles seulement vers le cloud

Chantier 2 sur 4 (après `2026-11-14-litellm-foundations-design.md`, fusionné
en #167). Reste : (3) MCP et tools, (4) agents, skills, mémoire.

## Intention

Les informations personnelles (Loi 25) ne doivent pas partir chez Anthropic,
Google ou OpenAI. Elles peuvent rester sur les Macs de Nicolas : les modèles
locaux (Ollama) doivent voir les vraies données, sinon un tri de courriel ou
une tâche d'agenda reçoit `<EMAIL_ADDRESS>` à la place du contenu.
Aujourd'hui `pii-identifiants` (`litellm/config.yaml`) masque **tout**, y
compris le trafic local, et les noms de personnes ne se masquent que si une
clé ou une requête le demande.

## Buts

- Masquer avant l'envoi toute requête qui part vers un modèle cloud ; ne rien
  toucher pour les modèles locaux.
- Masquer les identifiants (NAS, RAMQ, permis, passeport, cartes, comptes,
  courriels, téléphones, adresses civiques, codes postaux) pour toutes les
  teams ; ajouter les noms de personnes (français et anglais) pour `admin`,
  `famille` et `apps` (du texte courant), pas pour `dev-sessions` (du code).
- Échouer fermé : Presidio arrêté, ou texte qu'on ne sait pas lire, la requête
  cloud est refusée, jamais envoyée en clair.
- La politique (qui est masqué comment) vit dans un fichier du dépôt, relu en
  PR et vérifié par `make test`.

## Non-buts

- Masquer la réponse du modèle, injection de prompt, modération, guardrails
  Enterprise, limites de débit.
- Les outils MCP (`pre_mcp_call`) : chantier 3.
- Une licence Enterprise (écartée par Nicolas : approche B).

## Anti-buts (l'échec même si ça marche)

- Un seul chemin par lequel du texte non masqué atteint un fournisseur cloud :
  un modèle ajouté dans l'interface d'administration avec un nom libre, la clé
  maître, une équipe inconnue, du contenu en blocs (`/v1/messages`), le champ
  `system`, le texte récupéré par `second-brain`, un outil dont les arguments
  portent du texte.
- Un masquage qui s'applique encore au local « par prudence ».
- Un guardrail qui laisse passer en silence quand il plante.

## Contraintes

- Édition OSS de LiteLLM `v1.83.14-stable` : les guardrails par modèle, par
  clé et les `policy_attachments` par team sont Enterprise. Le guardrail
  personnalisé (`CustomGuardrail`) est dans l'édition OSS.
- Presidio est déjà déployé (`presidio-analyzer`, `presidio-anonymizer`, sur
  `infra-net`, reconnaisseurs et seuils dans `presidio/recognizers.yaml` et
  `litellm/config.yaml`). Le guardrail les appelle en HTTP ; il ne les
  réimplémente pas. Seuils actuels : 0,5 partout, 0,4 pour `CA_BANK_ACCOUNT`.
- Le conteneur `litellm` est une image épinglée : le code du guardrail est un
  fichier monté en lecture seule (`${INFRA_DIR:-.}/litellm/...:ro`, comme
  `config.yaml`), pas une image reconstruite.
- Même discipline que le reste du dépôt : rien dans l'image, secrets hors
  dépôt, `make test` sans pile vivante.

## Approches considérées

- **A. Licence Enterprise** : guardrails par modèle et policies par team, config
  très courte. Coût récurrent et contact commercial. Écartée.
- **B. Guardrail personnalisé OSS**, décidant par modèle et par team, qui
  appelle Presidio. **Choisie par Nicolas.**
- **C. Masquer partout** (l'existant) : va contre le but. Écartée.
- **D. Deux proxies LiteLLM** : coupe le plafond de 200 $ CAN en deux. Écartée.
- Écarté aussi : faire passer `guardrails:` par chaque client (un oubli fait
  fuir des données).

## Décisions de Nicolas

- Les infos personnelles ne posent problème que lorsqu'elles partent chez un
  fournisseur cloud ; le local n'est pas masqué.
- Approche B.
- **Images, fichiers et audio vers un modèle non local : refusés** (400), parce
  que Presidio ne lit que du texte. Les modèles locaux les acceptent comme
  avant. Coût assumé : pas de capture d'écran dans Claude Code via un alias
  `cloud-*`.

## Décisions de conception (mes choix, à corriger)

- **La règle est inversée : tout est masqué sauf une liste blanche de modèles
  locaux.** Le guardrail ne cherche pas « est-ce du cloud ? » (un modèle ajouté
  dans l'interface sous un nom libre serait alors envoyé en clair) ; il laisse
  passer seulement les alias listés comme locaux. Tout le reste, y compris un
  alias inconnu, est masqué.
- **Fichier de politique :** `litellm/pii_policy.yaml`, monté dans le conteneur,
  avec `local_models: [...]`, `entities` (le jeu d'identifiants), `names:
  [fr, en]`, et par team les groupes appliqués (`identifiants`, `noms`), plus
  un `default` pour une team absente. **Équipe inconnue ou clé maître (pas de
  team) : le jeu le plus strict, identifiants et noms.**
- **Valeurs initiales :** `local_models` = `qwen3.8:27b-mlx`,
  `gemma4:26b-a4b-it-qat`, `qwen3-embedding:0.6b` ; `admin`, `famille`, `apps` :
  identifiants et noms ; `dev-sessions` : identifiants seulement.
- **Un seul guardrail `cloud-pii`, `default_on: true`, mode `pre_call`** qui
  remplace `pii-identifiants`, `pii-noms-fr` et `pii-noms-en` dans
  `config.yaml`. Le masquage reste un remplacement par `<TYPE_ENTITE>`.
- **Couverture du texte :** `messages` (chaînes et blocs `text`), le champ
  `system` et l'`input`/`prompt` des autres formats. Un bloc image, fichier,
  document ou audio, ou tout bloc d'un type inconnu, fait refuser la requête
  non locale (voir la décision de Nicolas ci-dessus).
- **Texte récupéré par `second-brain` :** la doc dit que les guardrails
  `pre_call` en `default_on` le scannent aussi. Si le test sur proxy vivant
  montre que ce n'est pas le cas pour un guardrail maison, repli : refuser
  (400) toute requête non locale qui porte `vector_store_ids` ou un outil
  `file_search`.
- **Le contenu des outils** : les blocs `tool_result` (texte imbriqué) et les
  arguments des `tool_use` (chaînes dans le JSON) sont masqués comme le reste ;
  Claude Code en envoie en continu, on ne les refuse donc pas.
- **Réutiliser Presidio, pas le réécrire.** Le guardrail s'appuie sur le code
  du guardrail Presidio intégré s'il se laisse réutiliser (seuils, remplacement
  `<TYPE>`, `CA_BANK_ACCOUNT` à 0,4) ; sinon il appelle `/analyze` et
  `/anonymize` lui-même avec les mêmes valeurs. Les noms se masquent en deux
  passes, français puis anglais.
- **Pas de fallback du local vers le cloud.** `config.yaml` n'en déclare aucun,
  et un test de `make test` échoue si un `fallbacks:` en ajoute un : la
  décision de masquage se prend sur l'alias demandé, avant le routage.
- **Cohérence vérifiée par `make test`** : les teams de `pii_policy.yaml` sont
  celles de `teams.yaml`, les `local_models` existent dans `config.yaml`, et
  aucun d'eux ne parle à un fournisseur (`anthropic/`, `gemini/`, `openai/`).
- **Clé sans team** (clé d'un utilisateur seul, clé maître) : le jeu le plus
  strict, identifiants et noms. Ça active les noms pour une clé personnelle, ce
  qui est voulu : sans team, on ne sait pas quoi relâcher.
- **Texte long :** analysé en tranches coupées aux fins de ligne, avec un
  petit recouvrement pour ne pas couper un courriel ou un NAS ; jamais de 400
  pour cause de taille. Un délai dépassé ou une erreur de Presidio refuse la
  requête non locale (échec fermé).
- **Embeddings** vers un modèle non local : masqués comme le reste (aucun
  modèle d'embedding cloud n'existe aujourd'hui).
- **`second-brain` vers un modèle non local : refusé par défaut.** Le garde-fou
  (400 si la requête porte `vector_store_ids` ou un outil `file_search`) est
  livré actif. On ne l'enlève qu'après la vérification sur proxy vivant, dans
  un changement à part. Cette vérification n'est donc pas une porte de fusion,
  mais cloud et `second-brain` ne se combinent pas tant qu'elle n'est pas faite.
- **Un seul changement** retire `pii-identifiants`, `pii-noms-fr` et
  `pii-noms-en` de `config.yaml` et ajoute `cloud-pii` ; un test vérifie que
  `cloud-pii` est le seul guardrail `default_on`.

## Laissé à l'implémenteur

- La signature exacte des hooks pour `v1.83.14` (`async_pre_call_hook` et ses
  variantes selon le type d'appel : complétion, `/v1/messages`, réponses,
  embeddings) et la façon dont `config.yaml` charge un fichier monté.
- Le format exact des appels `/analyze` et `/anonymize` de Presidio, le
  découpage de texte long, le délai d'attente.
- Les tests : au minimum, par modèle local / cloud / inconnu et par team, que
  les identifiants (et les noms selon la team) sont masqués, que Presidio
  arrêté fait refuser une requête non locale et laisse passer une locale, et
  qu'un test de `make test` échoue si un modèle de `config.yaml` qui parle à un
  fournisseur (`anthropic/`, `gemini/`, `openai/`) figure dans `local_models`.
- Une vérification sur proxy vivant (hors `make test`) : une requête locale
  arrive intacte, une requête cloud arrive masquée, le texte de `second-brain`
  aussi.
- La documentation : `CLAUDE.md` (entrée `presidio-*` et `litellm`) et `README.md`.
