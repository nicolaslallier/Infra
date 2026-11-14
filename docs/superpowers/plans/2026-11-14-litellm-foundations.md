# LiteLLM foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cloud models (Anthropic, Gemini, OpenAI) behind LiteLLM virtual keys, with four teams, internal users, keys and a 200 $ CAN/month cap, all declared in `litellm/teams.yaml` and applied by an idempotent script.

**Architecture:** `litellm/teams.yaml` is the single source for budgets (in CAD). `scripts/litellm_provision.py` (Python stdlib + PyYAML, run through `uv`) validates the file against `litellm/config.yaml`, then upserts teams, users and keys through LiteLLM's admin API with the master key. The pure parts (validation, CAD to USD, drift) are unit-tested in `make test`; the API part is tested against a fake client.

**Tech Stack:** Python 3.12 (stdlib `urllib`, `yaml`), `uv`, GNU Make, Docker Compose, LiteLLM `v1.83.14-stable`.

**Spec:** `docs/superpowers/specs/2026-11-14-litellm-foundations-design.md`

## Global Constraints

- Local models cost 0 $ in LiteLLM: never invent a price for them.
- LiteLLM counts in USD; `teams.yaml` is in CAD with one `cad_to_usd` factor; the script converts.
- Global cap 200 $ CAN, reset every 30 days (`litellm_settings.max_budget` in USD + `budget_duration: 30d`). Team caps (CAD): `admin` 30, `famille` 30, `apps` 70, `dev-sessions` 70; they sum to the global cap.
- Teams: `admin`, `famille`, `apps`, `dev-sessions`. Cloud is opt-in per team through `models:` (aliases only, no wildcard); every list includes `qwen3-embedding:0.6b`; only `admin` sees all.
- `pii-identifiants` stays `default_on: true`; no key in the file opts out.
- Provider keys `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`: flat `.env` keys (vault `infra/env`), listed in `.env.example`, required non-empty and not `change-me` by `check-env`, read in `config.yaml` by `os.environ/NAME`. Never in the repo or in a log.
- Never change `LITELLM_SALT_KEY`.
- Virtual keys are printed once on stdout, everything else on stderr; an existing key is never replaced, `--rotate <alias>` issues a new one.
- A re-run updates existing teams/users from the file (UI edits are overwritten) and only reports, never deletes, objects absent from the file.
- Family users: created without invitation or automatic key; their key has no cap of its own.
- Out of scope: `guardrails:`/`mcp_servers:` changes, rpm/tpm limits, migrating clients off the master key, `devbox` wiring, SSO.

## Review Focus

- A team cap sum that differs from the global budget (someone edits one number) is rejected before any API call.
- A typo in a team's `models:` (silent loss of access) is rejected, as is a list without `qwen3-embedding:0.6b` (breaks RAG and the MCP filter for that team).
- A team without a cap (LiteLLM treats a missing `max_budget` as unlimited) or a non-positive `cad_to_usd` is rejected.
- A second run against unchanged state sends no `/key/generate` and prints no key.
- A key naming an unknown team, or a missing `LITELLM_MASTER_KEY`, fails with a message that names it.
- Objects present in LiteLLM but absent from the file are listed on stderr and left alone.

---

## File Structure

- `litellm/teams.yaml` (create): the declarative spec.
- `scripts/litellm_provision.py` (create): `validate`, conversion, drift, `apply`, CLI.
- `scripts/test_litellm_provision.py` (create): plain-assert tests, no framework.
- `litellm/config.yaml`, `docker-compose.platform.yml`, `.env.example`, `scripts/check-env.sh`, `scripts/test.sh`, `Makefile`, `CLAUDE.md`, `README.md` (modify).

### Task 1: Cloud models and provider keys

**Files:**
- Modify: `litellm/config.yaml` (model_list), `docker-compose.platform.yml:174-186` (litellm environment), `.env.example` (LiteLLM section), `scripts/check-env.sh:74-78` (required secrets list), `scripts/test.sh` (check-env rejection cases)

**Interfaces:**
- Produces: model aliases `cloud-anthropic`, `cloud-gemini`, `cloud-openai` (Task 2 lists them in team `models:`).

- [ ] **Step 1: Write the failing check.** In the check-env rejection cases of `scripts/test.sh` (read the existing loop first and follow its form), add cases asserting that `check-env` rejects a `.env` where `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` or `OPENAI_API_KEY` is empty or `change-me`.
- [ ] **Step 2: Run `make test`.** Expected: the three new cases FAIL (check-env accepts them).
- [ ] **Step 3: Implement.** Add the three keys to `check-env.sh`'s required-secrets array and to `.env.example` (`change-me`, one comment line each saying where the key comes from); pass them to the `litellm` service as `NAME: ${NAME:?Set NAME in .env}`; add three `model_list` entries (`model_name` = the aliases above, `litellm_params.model` = `anthropic/claude-sonnet-5-5`, plus a mid-tier Gemini and OpenAI model whose current ids you confirm in LiteLLM's provider docs, `api_key: os.environ/NAME`). No `order:` and no fallback to or from local models.
- [ ] **Step 4: Run `make test`.** Expected: all pass, including `docker compose config` and the fake-env baseline (if `ci-fake-env.sh` does not fill the new keys, teach it the same way it fills `LITELLM_MASTER_KEY`).
- [ ] **Step 5: Commit** `feat(litellm): cloud models and provider keys`.

### Task 2: Spec file, validation and the global cap

**Files:**
- Create: `litellm/teams.yaml`, `scripts/litellm_provision.py`, `scripts/test_litellm_provision.py`
- Modify: `litellm/config.yaml` (`litellm_settings`), `scripts/test.sh` (run the new test)

**Interfaces:**
- Produces: `load_spec(path: str) -> dict`; `to_usd(cad: float, rate: float) -> float` (2 decimals); `validate(spec: dict, config: dict) -> list[str]` (error messages, empty when valid). `spec` keys: `cad_to_usd: float`, `global_budget_cad: float`, `teams: {alias: {max_budget_cad: float, models: [str]}}`, `users: [{email: str, team: str}]`, `keys: [{alias: str, team: str, user: str|None}]`. `config` is the parsed `config.yaml`.

- [ ] **Step 1: Write failing tests** in `scripts/test_litellm_provision.py`, one function each, run by a `__main__` that calls every `test_*`: `test_to_usd_converts_and_rounds` (`to_usd(200, 0.72) == 144.0`), `test_valid_spec_passes`, `test_team_caps_must_sum_to_global`, `test_unknown_model_alias_is_rejected`, `test_missing_embedding_model_is_rejected`, `test_team_without_cap_is_rejected`, `test_non_positive_rate_is_rejected`, `test_key_with_unknown_team_is_rejected`, `test_config_cap_must_match_spec` (config `max_budget` differs from `to_usd(global_budget_cad, cad_to_usd)`), and `test_repo_files_are_consistent` (loads the real `litellm/teams.yaml` and `litellm/config.yaml` and asserts `validate(...) == []`).
- [ ] **Step 2: Run** `uv run -q --no-project --with pyyaml python scripts/test_litellm_provision.py`. Expected: FAIL, module missing.
- [ ] **Step 3: Implement** the three functions. `validate` checks every Review Focus line above that is file-level; model aliases are those in `config['model_list']` plus none other.
- [ ] **Step 4: Write `litellm/teams.yaml`**: header comment (CAD, one conversion factor, edit then `make litellm-provision`), `cad_to_usd` set to a clearly commented placeholder the owner must confirm at delivery, `global_budget_cad: 200`, the four teams with the caps and model lists from Global Constraints, `keys:` one per known app (`jarvis`, `darkangel`, `ea`, `ai` in `apps`; `nicolas-admin` in `admin`; one `dev-sessions` key), and `users: []` with a commented example for the family (names and emails are the owner's to add). In `config.yaml` set `litellm_settings.max_budget` (USD, with a comment pointing at `teams.yaml`) and `budget_duration: 30d`.
- [ ] **Step 5: Add to `scripts/test.sh`**, in the unit-tests section, a run of the test command from Step 2 reported through `pass`/`fail`.
- [ ] **Step 6: Run `make test`.** Expected: PASS, `test_repo_files_are_consistent` included.
- [ ] **Step 7: Commit** `feat(litellm): declarative teams, budgets and global cap`.

### Task 3: Applying the spec through the API

**Files:**
- Modify: `scripts/litellm_provision.py`, `scripts/test_litellm_provision.py`

**Interfaces:**
- Consumes: `load_spec`, `to_usd`, `validate` (Task 2).
- Produces: `class Client` with `request(method: str, path: str, body: dict | None = None) -> dict` (the only network surface; tests replace it); `apply(spec: dict, client, rotate: str | None = None) -> dict[str, str]` returning `{key_alias: new_key}` for keys it created or rotated.

- [ ] **Step 1: Confirm the API shapes** for v1.83.14 (docs via context7): `/team/new`, `/team/update`, `/team/info`, `/user/new`, `/user/update`, `/user/info`, `/key/generate`, `/key/list`, `/key/delete`. Prefer an explicit `team_id` equal to the alias and `user_id` equal to the email if accepted. Write what you found as the fake client's behavior.
- [ ] **Step 2: Write failing tests** against a `FakeClient` that stores teams/users/keys in dicts and records calls: `test_first_run_creates_teams_users_and_keys` (team `max_budget` is the USD value, `budget_duration` `30d`, `models` as in the file; users get no invitation and no auto key), `test_second_run_creates_no_key_and_returns_empty` (no `/key/generate` call), `test_changed_cap_is_pushed_to_existing_team`, `test_rotate_issues_a_new_key_for_one_alias`, `test_objects_absent_from_file_are_reported_not_deleted` (no delete call; the report names them), `test_no_secret_in_error_messages`.
- [ ] **Step 3: Run the test file.** Expected: the six new tests FAIL.
- [ ] **Step 4: Implement `Client`** (urllib; bearer master key; `ssl` context from a CA file; non-2xx raises with the response body, never the key) and `apply`. Reconcile by alias: update when it exists, create otherwise; report drift on stderr.
- [ ] **Step 5: Run the test file and `make test`.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(litellm): idempotent provisioning of teams, users and keys`.

### Task 4: CLI, Make target and docs

**Files:**
- Modify: `scripts/litellm_provision.py` (`main`), `Makefile`, `CLAUDE.md` (the `litellm` entry under Architecture), `README.md`

**Interfaces:**
- Consumes: `apply`, `validate`, `Client`.
- Produces: `make litellm-provision [rotate=<alias>]`.

- [ ] **Step 1: Write failing tests**: `test_main_fails_naming_missing_master_key` (empty `LITELLM_MASTER_KEY` → exit code 1, message names the variable), `test_main_prints_keys_on_stdout_only` (stdout lines are `alias<TAB>key`, nothing else; stderr carries progress), `test_main_refuses_invalid_spec_before_any_request` (a spec with mismatched caps makes zero client calls).
- [ ] **Step 2: Run the test file.** Expected: FAIL.
- [ ] **Step 3: Implement `main(argv: list[str], env: dict, client=None) -> int`**: reads `LITELLM_MASTER_KEY` from the process environment (the wrapper sources `.env` like `provision-litellm-rag.sh`), base URL `LITELLM_URL` (default `https://litellm.infra.famillelallier.net`), CA `certs/infra-ca.crt`, `--rotate <alias>` flag, validates first.
- [ ] **Step 4: Add the Make target** `litellm-provision: check-env` in the style of `ntfy-provision` (add it to `.PHONY`), running the script with `uv run -q --no-project --with pyyaml python scripts/litellm_provision.py` after sourcing `.env`.
- [ ] **Step 5: Document**: update the `litellm` entry in `CLAUDE.md` (teams, caps, source of truth, keys shown once, the CAD factor to revisit, that `devbox`/apps still use the master key until the owner switches them) and add a short "LiteLLM: teams and budgets" section to `README.md` with the owner's first-run sequence: add the three provider keys to the vault, `make vault-env`, merge, `make up stack=platform`, set `cad_to_usd`, `make litellm-provision`, store the printed keys.
- [ ] **Step 6: Run `make test` and `make -n litellm-provision`.** Expected: PASS; the dry run shows the script call.
- [ ] **Step 7: Commit** `feat(litellm): make litellm-provision and docs`.
