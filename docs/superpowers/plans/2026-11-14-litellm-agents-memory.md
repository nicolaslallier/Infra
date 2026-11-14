# LiteLLM memory, closed skills, no agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/v1/skills`, `/a2a/` and `/v1/a2a/` are refused for LAN clients; LiteLLM's native `/v1/memory` is documented and checkable per team; no agent is registered.

**Architecture:** Three nginx location rules in `nginx/conf.d/litellm.conf` (403, like the existing pass-through block), a stdlib test that reads the real vhost, and documentation. No LiteLLM config change: `/v1/memory` is native, scoped by the key's `user_id`/`team_id`, and is not read back into prompts by LiteLLM.

**Tech Stack:** nginx, Python 3 stdlib test, Markdown.

**Spec:** `docs/superpowers/specs/2026-11-14-litellm-agents-memory-design.md`

## Global Constraints

- nginx stays the single ingress; no `ports:` anywhere, no new service.
- The new rules must not block `/v1/chat/completions`, `/v1/messages`, `/v1/models`, `/v1/memory`, `/mcp`, `/ui`, `/v1/agents` (the admin registry the UI uses).
- A container calling `litellm:4000` directly bypasses nginx: say so in the docs, as chantiers 2 and 3 did.
- `make test` needs Docker and is not available here: the new test must run standalone with `python3`.

## Review Focus

- A path spelled differently (`/V1/Skills`, `//v1/skills`, `/v1/skills/abc`, `/a2a/x/message/send`) still hits the 403 rule: the location is case-insensitive (`~*`) and the test checks the regex with these spellings.
- Ordinary routes are not caught by the rule (`/v1/skillset-not-a-route` is not a LiteLLM route but `/v1/memory`, `/v1/messages`, `/mcp`, `/v1/agents` must pass).
- The 403 block sits before `location /` and does not remove the headers or limits `location /` sets for other routes.

---

### Task 1: Close skills and A2A in the vhost

**Files:**
- Create: `scripts/test_litellm_routes.py`
- Modify: `nginx/conf.d/litellm.conf`, `scripts/test.sh` (run the new test next to the other LiteLLM blocks)

**Interfaces:**
- Produces: a `location ~* ^/(v1/skills|a2a|v1/a2a)(/|$)` block returning 403 in `litellm.conf`; the test file's `blocked_pattern()` reads that regex from the file.

- [ ] **Step 1: Write the failing test** `scripts/test_litellm_routes.py` (plain asserts, `if __name__ == "__main__"` runner like `scripts/test_mcp_policy.py`): `blocked_pattern()` extracts the regex of the `location ~*` block whose body is `return 403;` and mentions `skills`; `test_skills_and_a2a_are_refused` asserts `re.search(pattern, path, re.I)` matches `/v1/skills`, `/v1/skills/abc`, `/V1/Skills`, `/a2a/x`, `/a2a/x/message/send`, `/v1/a2a/x/message/send`; `test_ordinary_routes_pass` asserts it does not match `/v1/chat/completions`, `/v1/messages`, `/v1/models`, `/v1/memory`, `/v1/memory/k`, `/mcp`, `/ui`, `/v1/agents`, `/v1/agents/x`; `test_the_block_comes_before_the_catch_all` asserts its offset in the file is below `location / {`.
- [ ] **Step 2: Run it to see it fail** — Run: `python3 scripts/test_litellm_routes.py` — Expected: FAIL (no such block).
- [ ] **Step 3: Add the block** to `nginx/conf.d/litellm.conf` before `location / {`, with a comment saying why: skills go to Anthropic past the PII gate, A2A agents are decided by a policy that does not exist yet (re-open only for a named agent), and a container calling `litellm:4000` is not covered.
- [ ] **Step 4: Run it to see it pass** — Run: `python3 scripts/test_litellm_routes.py` — Expected: all ok.
- [ ] **Step 5: Wire into `scripts/test.sh`** in the `## LiteLLM: MCP tools` region with the same `pass`/`fail` idiom as its neighbours; `bash -n scripts/test.sh`.
- [ ] **Step 6: Commit** `feat(litellm): refuse skills and A2A routes at the vhost`.

### Task 2: Document memory, closed skills and the absent agent

**Files:**
- Modify: `CLAUDE.md` (the `litellm` entry), `README.md` (new `## LiteLLM: memory, skills, agents` section after the MCP one), `scripts/test_litellm_routes.py` (docs test)

**Interfaces:**
- Consumes: Task 1's closed routes.

- [ ] **Step 1: Write the failing docs test** `test_docs_say_memory_is_per_team_skills_are_closed_and_there_is_no_agent`: `CLAUDE.md` contains `/v1/memory`, `/v1/skills` and `A2A`; `README.md` contains the heading `## LiteLLM: memory, skills, agents`, `/v1/memory`, `users: []`, and `litellm:4000`.
- [ ] **Step 2: Run it to see it fail** — `python3 scripts/test_litellm_routes.py`.
- [ ] **Step 3: Write the docs.** `CLAUDE.md`: add to the `litellm` entry that memory is native `/v1/memory` (rows scoped by `user_id`/`team_id`, keys have no user today so it is per team, never read back by LiteLLM, masked only if re-sent to a cloud model), that `/v1/skills` and A2A routes are 403 at the vhost, that Jarvis does not speak A2A so no agent is registered, and the direct-container limit. `README.md` section: the key convention `<agent>/<subject>`, short values, never a secret; the live checks as `curl` blocks with the `jarvis`, `ea`, `famille` and a team-less key (jarvis writes `PUT /v1/memory/jarvis/test`; ea sees it; famille does not; a key with no team sees nothing; `GET /v1/skills` through the vhost is 403); how to open an agent later (A2A only for a named agent: reopen `/v1/a2a/` for it, check whether the pre-call hook runs for A2A, add the team check in the gate); the note that adding family members to `users:` makes memory per person.
- [ ] **Step 4: Run the test to see it pass** — `python3 scripts/test_litellm_routes.py`; then the other suites still pass (`test_mcp_policy`, `test_pii_policy`, `test_litellm_provision` with `uv run -q --no-project --with pyyaml`).
- [ ] **Step 5: Commit** `docs(litellm): memory, closed skills, no agent yet`.
