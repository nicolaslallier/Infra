# Sort the Gmail inbox with Ollama

Status: draft 2026-09-27

## Goal

A Prefect flow, `sort-mail`, that files the Gmail inbox of
nicolas.lallier@famillelallier.net (Google Workspace): for each inbox thread,
Ollama reads the latest message and picks one of the user's existing `Tri/*`
labels, or `garder`. A filed thread gets the label and leaves the inbox
(label + archive); a kept thread stays. The existing inbox backlog drains
gradually, newest first, a bounded number of threads per run.

Same conventions as `organize-inbox` (CLAUDE.md, "Prefect: pipelines"): the
flow owns the control flow, the model owns only the judgement; the reply is
constrained by a JSON schema whose `enum` is built per run and validated again
before it is acted on; one item at a time; one run at a time.

## Decisions

| Question | Decision |
|---|---|
| Mailbox | Gmail / Google Workspace, one account |
| What "sort" does | Add a `Tri/*` label and remove `INBOX` (archive) |
| Categories | Existing Gmail labels under `Tri/`, excluding names starting with `_`; plus `garder` |
| Which mail | The whole inbox, gradually: at most `SORTER_MAX_THREADS` (20) per run, newest first |
| Access | Gmail REST API + OAuth refresh token (not IMAP, not a service account) |
| Secret | Prefect Secret block `gmail-sorter-oauth`, not `.env` |

## Architecture

One file, `prefect/flows/sort_mail.py`, flow `sort-mail`, registered in
`serve.py` as deployment `every-15m` with `ONE_AT_A_TIME`. No new container,
no new pip package: HTTP goes through `urllib.request`, as `classify()` in
`organize_inbox.py` already does.

### Gmail access

- Every run starts with `POST https://oauth2.googleapis.com/token`
  (`grant_type=refresh_token`) for a fresh access token (1 h lifetime; a run
  is shorter). No caching: each flow run is its own subprocess of
  `prefect-flows`, so an in-memory cache would not survive between runs anyway.
- Calls: `GET users/me/labels`, `GET users/me/threads?q=...`,
  `GET users/me/threads/{id}?format=full`,
  `POST users/me/threads/{id}/modify`, all with `Authorization: Bearer`.
- Scope: `https://www.googleapis.com/auth/gmail.modify`, the narrowest scope
  that can add/remove labels on messages. It cannot delete permanently.
- The Secret block `gmail-sorter-oauth` holds JSON
  `{"client_id": ..., "client_secret": ..., "refresh_token": ...}`, read with
  `Secret.load("gmail-sorter-oauth").get()`. It is a Secret block for the
  reason `pr-validation`'s PAT is: `.env` is handed to containers wholesale
  and shipped to Portainer, and this token reads all of the user's mail.

### One-time setup (documented, not automated)

1. Google Cloud Console: a project, the Gmail API enabled, an OAuth consent
   screen of type **Internal**. Internal is what makes this viable: an
   External app in Testing mode has its refresh tokens revoked after 7 days,
   and the flow would die weekly with `invalid_grant`.
2. An OAuth client of type **Desktop app**.
3. `scripts/gmail-oauth.py <client_secret.json>`: stdlib only. Opens the
   browser on the consent URL (`access_type=offline`, `prompt=consent`),
   receives the code on a one-shot `http://127.0.0.1:<port>` listener,
   exchanges it and prints the JSON to paste into the Secret block.
4. In Gmail, create the `Tri/...` labels. The label name is the model's only
   description of the category, so name them descriptively
   (`Tri/Factures et reçus`, not `Tri/Fin`).

## Data flow, per run

1. **Token**: refresh token → access token. `invalid_grant` fails the whole
   run, with a message saying to re-run `scripts/gmail-oauth.py`.
2. **Categories**: `labels.list`; keep user labels whose name starts with
   `Tri/` and whose remainder does not start with `_`. Map name → id. None
   left → `RuntimeError`, as `organize-inbox` does with no folders. The marker
   label `Tri/_garder` is created if missing (`labels.create`).
3. **Threads**: `threads.list` with `q=in:inbox -label:tri-_garder` and
   `maxResults=SORTER_MAX_THREADS`, first page only (Gmail returns newest
   first). Filed and kept threads no longer match, so the next page is never
   needed. Gmail search spells `/` and spaces in label names as `-`; the exact
   form is verified against the live API during implementation, since a query
   term that matches nothing would silently bring every kept thread back.
4. **Per thread, one at a time** (`sort_thread` task):
   - `threads.get?format=full`; take the last message.
   - Build the model input: `From`, `To`, `Subject`, `Date`, whether
     `List-Unsubscribe` is present, attachment filenames, and the body:
     the first `text/plain` part, else the first `text/html` part with tags
     stripped by `html.parser.HTMLParser`; walked recursively through
     `multipart/*`; `body.data` is base64url. Cut to `MAX_CHARS` (8000).
   - Ollama `POST /api/chat`, `temperature 0`, `format` =
     `{"category": enum[<Tri/* names>, "garder"], "reason": string}`.
     System prompt: pick the category the email belongs to; answer `garder`
     if it awaits a reply or a personal action from the user, or if no
     category clearly fits; `reason` is one sentence.
   - `parse_reply` validates it again (object, category in the enum,
     non-empty reason).
   - `garder` → `threads.modify(addLabelIds=[<Tri/_garder id>])`; the thread
     stays in the inbox and is not seen again. Removing that label by hand
     puts it back in the queue. A new reply in a kept thread does not
     re-sort it: the user already judged it needs attention.
   - otherwise → one `threads.modify(addLabelIds=[<label id>],
     removeLabelIds=["INBOX"])`. One call, so there is no half-applied state.
   - Log `"<subject>" -> <category> (<reason>)`.
5. The flow returns the task states, so the run is Failed if any thread
   failed while the rest are still sorted (as `organize-inbox`).

### Why threads, not messages

The inbox is shown by conversation. Removing `INBOX` from one message leaves
the thread visible while any other message in it carries `INBOX`, so labels
and archiving are applied to the thread and the latest message is what gets
classified.

### `dry_run: bool = False`

A flow parameter. When true, step 4 logs the decision and skips every
`modify` and the marker `labels.create`. A parameter rather than an env var:
it changes per run from the UI, without a `make up` (which would briefly drop
LAN DNS along with everything else).

**Rollout: the deployment starts dry.** `serve()` registers deployments live
and every push to main deploys through CI, so "run a dry run by hand first"
would race the schedule. The first release registers `sort-mail/every-15m`
with `parameters={"dry_run": True}` (pinned by a test in `test_serve.py`);
a second commit removes it once the user has read a scheduled dry-run log.

## Error handling

`retry_transient` as in `organize_inbox.py`, plus HTTP status awareness:

| Failure | Behaviour |
|---|---|
| Ollama or Gmail unreachable, HTTP 429, HTTP 5xx | task retried (2 retries, 30 s) |
| Invalid model reply (`ValueError`) | thread fails, not retried; stays in the inbox, retried next run |
| Other Gmail HTTP 4xx | thread fails, not retried |
| `invalid_grant` on token refresh | whole run fails, message names `scripts/gmail-oauth.py` |
| No `Tri/*` label | `RuntimeError` |

`urllib.error.HTTPError` is a subclass of `URLError`/`OSError`, so the retry
check must look at `.code` before falling through to "anything else may be
transient".

Known ceiling, marked `ponytail:` in the code: a thread that fails the same
way every run (bad reply at temperature 0) stays at the top of the inbox and
takes one of the `SORTER_MAX_THREADS` slots on each run. If that ever
matters: tag non-retryable failures with `Tri/_garder` too.

Ollama is shared with `organize-inbox`. Each deployment has a limit of 1,
but the two may run at the same time; their requests then queue inside
Ollama (~30 s each, far under the 300 s timeout). No cross-deployment lock.

## Configuration

`prefect-flows` environment in `docker-compose.yml` (not `PREFECT_*`,
Prefect owns that namespace):

- `SORTER_MAX_THREADS` (default `20`)
- `SORTER_LABEL_PREFIX` (default `Tri/`)
- `OLLAMA_URL`, `OLLAMA_MODEL`: already there, shared.

The keep marker is `<prefix>_garder`; not configurable.

## Testing

`prefect/flows/test_sort_mail.py`, plain asserts, run like the others:
`uv run --no-project --python 3.12 --with prefect==3.8.7 python prefect/flows/test_sort_mail.py`.

- label filtering to the enum (prefix, `_` exclusion, system labels ignored);
- the `threads.list` query string;
- `parse_reply` (unknown category, empty reason, non-object);
- message text extraction: `text/plain`, HTML only, nested multipart,
  base64url without padding, `List-Unsubscribe` flag, attachment names;
- `retry_transient`: `ValueError` and HTTP 404 not retried, 429/503 and
  `URLError` retried;
- `sort_thread` against an in-memory fake Gmail and a stubbed `classify`:
  a category sends exactly one `modify` with add + remove `INBOX`; `garder`
  adds only the marker; `dry_run` sends none.

`test_serve.py` already asserts every deployment has a limit of 1 with
`CANCEL_NEW`, so it covers the new one; it gains a temporary
`test_sort_mail_starts_dry`, deleted with the dry-run parameter.

Acceptance on the live stack: a `dry_run` run over the real inbox whose log
reads sensibly, then one real run of 20 threads checked in Gmail.

## Documentation

A `#### sort-mail` subsection under "Prefect: pipelines" in `CLAUDE.md`:
what it does, the thread/marker behaviour, the Secret block, the 4-step
setup, and the Internal consent screen requirement.

## Out of scope

IMAP, other mailboxes, several accounts, replies/drafts, deleting mail,
summaries or tags written anywhere, per-category descriptions beyond the
label name, a cross-deployment Ollama lock.
