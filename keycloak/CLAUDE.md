# Keycloak realms and oauth2-proxy gates

Moved out of the root CLAUDE.md so it loads only when working here.

## Jarvis: Keycloak login gate (oauth2-proxy)

`jarvis.famillelallier.net` (and its `.infra.` alias) is one of the two
application vhosts in this repo that require a login — the other is
Obsidian, which runs the same recipe against a different realm through its
own `oauth2-proxy-ea` container (see the `obsidian` service above). Every
other backend app listed in "Single-ingress rule" above is reachable by
anyone who can resolve its hostname. The gate is the standard
`oauth2-proxy` + NGINX `auth_request` recipe:

- **`keycloak/realm-import/jarvis-realm.json`** — a dedicated realm
  (`jarvis`), separate from `nurse-realm.json`, holding one confidential
  client (`clientId: jarvis`) with a single redirect URI
  (`https://jarvis.famillelallier.net/oauth2/callback`, owned by
  oauth2-proxy, not the Jarvis app itself). It deliberately omits both a
  client `secret` (Keycloak auto-generates one for a confidential client
  on import, so no secret value — even a placeholder — ever lands in git)
  and a `users` array (a real login password shouldn't live in a
  committed JSON file either). Both are manual admin-console steps after
  the first `make up` — see the `JARVIS_OAUTH_CLIENT_SECRET` comment in
  `.env.example`. This mirrors `nurse-realm.json`'s own seed-user
  precedent: `NURSE_SEED_PASSWORD`/`EXAMINER_SEED_PASSWORD` are likewise
  applied after boot via `make keycloak-seed-users`, not baked into the
  realm JSON.
- **`oauth2-proxy` service** (`docker-compose.yml`) — publishes no host
  port; reached only by `nginx` over `infra-net` at
  `oauth2-proxy:4180`. Its own `OAUTH2_PROXY_UPSTREAMS` is a dummy
  (`static://202`) because it's never used as an actual reverse proxy
  here, only as the `auth_request` subrequest target and the handler for
  `/oauth2/*` (sign-in, callback, logout). Points at Keycloak via the
  internal `http://keycloak:8080/realms/jarvis` issuer URL, not the
  external `https://keycloak.famillelallier.net` one, for the same
  same-network reason the `minio` service avoids `MINIO_SERVER_URL`
  (hairpinning back out through NGINX from inside `infra-net`). This
  internal-URL/external-issuer split hits a real Keycloak hostname-v2
  quirk — `KC_HOSTNAME` is set to the full external URL
  (`https://keycloak.famillelallier.net`, not a bare hostname) so the
  discovery document's `issuer` is stable regardless of which request
  triggers it, but that issuer then never matches the internal
  `OIDC_ISSUER_URL` used to fetch it, so strict verification always
  fails. `OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION=true` is
  therefore enabled — this is the documented escape hatch, deliberately
  on here rather than the exceptional case. oauth2-proxy's own
  server-to-server calls (token exchange, jwks) hit the endpoints named
  in that discovery doc, i.e. the external `https://keycloak.famillelallier.net`
  hostname — which otherwise has no route from inside `infra-net` — so
  the `nginx` service carries a `keycloak.famillelallier.net` network
  alias pointing that hostname back at itself (it already TLS-terminates
  and proxies it via `nginx/conf.d/keycloak.conf`). Those calls then hit
  the local dev CA (`certs/infra-ca.crt`), which isn't in oauth2-proxy's
  default trust store and whose distroless image has no shell for a
  `--provider-ca-file`-at-build-time trick; instead
  `scripts/gen-certs.sh`'s `gen_oauth2proxy_bundle` bakes a
  `certs/oauth2proxy-ca-bundle.crt` (the image's own CA bundle plus our
  CA) that's bind-mounted over `/etc/ssl/certs/ca-certificates.crt`, so
  every Go `http.Client` in the process picks it up via the system pool.
  The `keycloak` service also carries a `healthcheck` (`/health/ready` on
  its management port, probed with a `/dev/tcp` one-liner since the image
  ships no curl/wget) so `oauth2-proxy` can `depends_on: condition:
  service_healthy` instead of `service_started` — without it, oauth2-proxy
  starts as soon as Keycloak's container process launches, long before its
  HTTP listener is actually up, and its one-shot OIDC discovery call fails
  with a DNS/connection error that only clears on a lucky restart.
- **`nginx/conf.d/jarvis.conf`** — adds `location = /oauth2/auth`
  (internal-only `auth_request` target), `location /oauth2/` (proxies
  sign-in/callback/logout to oauth2-proxy), and gates the existing
  `location /` with `auth_request` + `error_page 401 = /oauth2/sign_in`.
  This only protects the frontend's static-file location — **it does
  not cover the Jarvis backend API or its `GET /ws/ingest-status`
  WebSocket.** Per the Jarvis repo's `frontend/src/useFiles.ts` and
  `frontend/Dockerfile`, `VITE_API_URL` is a browser-facing build-time
  value baked into the static bundle and pointed at the backend's own
  published host port (e.g. `http://localhost:8000`) — the browser calls
  `fetch()`/`new WebSocket()` against that URL directly, never through
  this NGINX vhost. So the usual "`auth_request` breaks WebSocket
  upgrades" failure mode doesn't apply here (there's no `auth_request` on
  a WS route in this file), but it also means logging into the frontend
  page does **not** by itself put the backend API/WebSocket behind
  Keycloak. Verify manually post-deploy: confirm what `VITE_API_URL` the
  deployed frontend was actually built with, and whether that backend
  port is reachable unauthenticated from outside the LAN.

## EA: token verification, no gateway

`keycloak/realm-import/ea-realm.json` seeds a dedicated realm (`ea`),
separate from `jarvis`/`nurse`, for the EA application in the `EA` repo.
It holds three clients — `ea-spa` (public, PKCE, the SPA's browser
sessions), `ea-mcp` (public, PKCE, an agent talking to `/mcp` via the same
authorization-code flow but with a loopback redirect since there is no
browser origin to restrict it to) and `ea-pipelines` (confidential, service
account only — no human ever logs in as it) — plus one realm role,
`ea-editor`, that gates writes (reading the catalogue needs no role). All
three clients carry an `oidc-audience-mapper` stamping `ea-api` into the
access token, because the EA API validates that audience rather than
trusting whichever client requested the token.

Every `redirectUris` entry is an **exact** callback, never a trailing
`*`: Keycloak's match for a trailing `*` is a plain string prefix, so
`http://localhost:*` also matches
`http://localhost:1234@evil.example/callback` (a browser reads `1234` as
userinfo and goes to `evil.example`) — a wildcard redirect is an open
redirect. `ea-spa` lists `https://ea.infra.famillelallier.net/auth/callback`
plus the two Vite-dev loopback forms, all at the SPA's one callback path;
its `post.logout.redirect.uris` attribute holds the matching bare origins,
`##`-joined (Keycloak's multi-value separator for that attribute, not a
JSON array); `webOrigins` stays `["+"]`, which derives allowed CORS origins
from those exact redirect URIs rather than naming its own wildcard. A LAN
origin for the Vite dev server is **not** a missing redirect URI: on plain
http (`http://192.168.x.y:5173`) the SPA cannot even start the login,
because PKCE needs `crypto.subtle` and browsers only expose it in a secure
context — so reach Vite as `http://localhost:5173` (from another machine,
`ssh -L 5173:127.0.0.1:5173 -L 8000:127.0.0.1:8000 <host>`) or through the
https vhost, never by adding the LAN origin in the console (EA
`docs/adr/0032`). `ea-mcp` lists exactly one redirect URI,
`http://localhost:33418/callback` — Claude Code (2.1.270) opens a loopback
callback on the port its own `.mcp.json` pins as `callbackPort` for
`clientId: ea-mcp`; the two numbers must always agree, so changing EA's
`.mcp.json` means changing this realm file (and the live realm) to match,
never the other way only.

Unlike Jarvis, there is **no oauth2-proxy and no `auth_request`** on the
EA vhost itself: the EA API and its `/mcp` transport verify the JWT
themselves (EA `docs/adr/0032`), so `nginx/conf.d/ea.conf` needs no change
and this realm adds no NGINX location *there*. Keycloak is still reached
the normal way, at `https://keycloak.famillelallier.net`.

The realm does have a fourth client that *is* an oauth2-proxy gate,
`ea-obsidian` — but it fronts Obsidian, not EA (see the `obsidian` service
above). It is the one client here with no `ea-api` audience mapper, because
nothing behind that gate calls the EA API; the token is only ever proof
that the person is an `ea` realm user. It carries its own
`ea-obsidian-audience` mapper instead, as `jarvis` does: oauth2-proxy's
keycloak-oidc provider rejects a token whose `aud` lacks its client id,
and without the mapper Keycloak stamps only `account` there (a bare 500
on `/oauth2/callback`, logged as `audience ... [account] does not match`). Its single redirect URI is
`https://obsidian.infra.famillelallier.net/oauth2/callback` — the same
exact-callback rule as every other client in this file, no trailing `*`.

`ea-realm.json` carries a **`users` array**, deliberately, where
`jarvis-realm.json` deliberately has none: `ea-pipelines`'s service
account is not a human who logs in with a password, it is how the worker
itself authenticates, so the only way to hand it the `ea-editor` role at
import time is a `users` entry named `service-account-<clientId>` with
`serviceAccountClientId` set and no `credentials` — Keycloak creates that
user automatically for any client with `serviceAccountsEnabled: true`, and
the import is just attaching a role to the user it will create anyway.
Nothing sensitive lands in the file: no password, and the confidential
client's secret is still Keycloak-generated on import, copied out of the
console afterwards exactly like `jarvis`'s.

`--import-realm` only seeds a realm that does not exist yet — editing this
file after the first `make up` does not touch the live `ea` realm; repeat
the change in the admin console too.
