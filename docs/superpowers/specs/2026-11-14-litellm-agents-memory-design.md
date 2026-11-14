# LiteLLM : mémoire, skills fermés, agents (petit chantier)

Chantier 4 sur 4 (après #167, #168 fusionnés et #169 MCP, ouverte : cette branche est
construite par-dessus). Petit changement : design court.

## Intention

Nicolas veut que la passerelle serve aussi à des agents, des skills et une mémoire, avec
les mêmes teams, budgets et règles Loi 25 que les chantiers précédents. Il a validé un
découpage en trois : mémoire, skills fermés, un seul agent (Jarvis) **si** c'est possible.

## Constats (LiteLLM 1.83.14, code lu ; Jarvis, dépôt lu)

- **Mémoire** (`/v1/memory`) : CRUD clé/valeur dans la base `litellm`. Lecture : les lignes
  dont `user_id` ou `team_id` est celui de la clé ; écriture : propriétaire seulement
  (l'admin du proxy peut tout). Une clé sans user ni team ne voit rien. LiteLLM ne la relit
  jamais dans un prompt : elle ne passe par aucune porte.
- **Skills** (`/v1/skills`) : relais vers l'API Skills d'Anthropic ; un skill envoyé part chez
  un fournisseur cloud, sans passer par la porte `cloud_pii`.
- **Agents** (A2A, `/a2a/{id}`, `/v1/a2a/{id}/message/send`) : LiteLLM enregistre l'adresse
  d'un agent existant et décide qui l'appelle ; il n'en fournit pas.
- **Jarvis ne parle pas A2A** (aucun `a2a`/`agent-card` dans le dépôt) et appelle LM Studio, pas
  LiteLLM. Il n'y a donc aucun agent à enregistrer aujourd'hui.
- Les clés de `teams.yaml` n'ont **aucun user** (`users: []`) : la mémoire est donc par team
  (`admin`, `apps`, `famille`, `dev-sessions`), pas par personne, tant que Nicolas n'a pas
  ajouté d'utilisateurs.

## Buts

- La mémoire LiteLLM est utilisable par chaque team et **cloisonnée** : une clé d'une team ne
  lit ni n'écrit la mémoire d'une autre, et une clé sans team ne voit rien.
- `/v1/skills` est refusé pour les clients du LAN, comme les routes pass-through.
- Aucun agent enregistré ; le jour où il y en aura un, le chemin pour le faire sans trou est écrit.

## Non-buts

- Un service d'agents maison, une recherche sémantique dans la mémoire, remplacer Jarvis ou le
  coffre Obsidian (la mémoire LiteLLM ne sert qu'aux petits faits des agents).
- Créer des utilisateurs de la famille (à Nicolas), rendre Jarvis compatible A2A.

## Anti-buts

- Une team qui lit la mémoire d'une autre ; un skill qui part chez Anthropic par la passerelle ;
  un agent A2A atteignable sans que la politique de teams le décide.

## Contraintes

- Le texte d'une mémoire n'est pas masqué dans la base (elle reste à la maison). S'il est
  remis dans un prompt vers un modèle cloud, la porte le masque comme tout message.
- nginx ne couvre pas un conteneur qui appelle `litellm:4000` directement (même limite qu'aux
  chantiers 2 et 3) : `/v1/skills` et `/a2a` y restent atteignables depuis `infra-net`.

## Approches

- **A (choisie par Nicolas) :** mémoire native + routes skills/A2A fermées + pas d'agent.
- B : service d'agents maison derrière la passerelle : beaucoup de code sans besoin vu. Écartée.
- C : refuser aussi `/v1/memory` et laisser Jarvis seul gérer la mémoire : plus simple, mais
  Nicolas voulait une mémoire pour les agents de la passerelle. Écartée.

## Décisions de conception (mes choix, à corriger)

- **Fermer `/v1/skills`, `/a2a/` et `/v1/a2a/` dans `nginx/conf.d/litellm.conf`** (403),
  avec un cas `make test` qui lit le fichier. Le jour d'un agent A2A, on rouvre `/v1/a2a/` pour
  lui et on ajoute le contrôle par team dans la porte (le hook A2A est à vérifier à ce moment).
- **Vérification de la mémoire sur proxy vivant** (clé `jarvis` écrit, clé `ea` lit : voit la
  ligne ; clé `famille` : ne la voit pas ; clé sans team : rien), consignée dans la liste de
  vérifications du README. Pas de test unitaire sur le code de LiteLLM lui-même (il faut sa base).
- **Convention de clés** documentée : `<agent>/<sujet>`, valeurs courtes, jamais de secret.
- `CLAUDE.md` (entrée `litellm`) et `README.md` mis à jour ; un contrôle de cohérence docs
  comme aux chantiers précédents.

## Laissé à l'implémenteur

La forme exacte des règles nginx (regex et ordre avec la règle existante), le texte du
cas `make test`, et les commandes `curl` de vérification.
