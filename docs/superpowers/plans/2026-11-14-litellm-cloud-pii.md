# LiteLLM cloud-only PII masking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `cloud-pii` guardrail that masks personal information only on requests to non-local models (per-team entity sets), refuses what Presidio cannot read, and leaves local traffic untouched.

**Architecture:** A pure policy module (`decide(policy, model, team)`) reads `litellm/pii_policy.yaml`; a thin `CloudPII` guardrail, a subclass of LiteLLM's built-in Presidio guardrail, overrides `apply_guardrail` (the unified hook LiteLLM already feeds from chat, `/v1/messages`, responses and embeddings) and calls the existing Presidio services. Files are bind-mounted into the pinned image; `make test` checks the policy against `teams.yaml` and `config.yaml`.

**Tech Stack:** Python 3.12, `uv`, LiteLLM `v1.83.14-stable` (version read from the compose image tag), Presidio over HTTP, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-11-14-litellm-cloud-pii-design.md`

## Global Constraints

- Rule is inverted: **everything is masked except the aliases in `local_models`**; an unknown alias is masked.
- `local_models`: `qwen3.8:27b-mlx`, `gemma4:26b-a4b-it-qat`, `qwen3-embedding:0.6b`. None may use an `anthropic/`, `gemini/` or `openai/` model.
- Groups per team: `admin`, `famille`, `apps` = `identifiants` + `noms`; `dev-sessions` = `identifiants`; no team or master key = `identifiants` + `noms`.
- Identifier entities and thresholds are those of today's `pii-identifiants` in `config.yaml` (NAS, RAMQ, permis SAAQ, passeport, bank account, credit card, IBAN, email, phone, street address, postal code; 0.5 everywhere, 0.4 for `CA_BANK_ACCOUNT`). Names: `PERSON`, two passes, `fr` then `en`. Replacement is `<ENTITY_TYPE>`.
- Fail closed for non-local requests: Presidio down, timeout or error refuses the request; local requests never call Presidio.
- Image, file, document and audio blocks, and blocks of an unknown type, to a non-local model: refused (HTTP 400). `tool_result` text and `tool_use` string arguments are masked, never refused.
- A non-local request carrying `vector_store_ids` or a `file_search` tool: refused (HTTP 400), until a later change removes it after live verification.
- Long text is scanned in chunks cut at line ends with a small overlap; never refused for size.
- No `fallbacks:` in `config.yaml`; `cloud-pii` is the only `default_on` guardrail; `pii-identifiants`, `pii-noms-fr`, `pii-noms-en` are removed in the same change.
- The guardrail code is mounted read-only from `litellm/`; the image is not rebuilt.

## Review Focus

- An alias added in the admin UI under a free name (not in `local_models`) is masked.
- An Anthropic `/v1/messages` request with `system`, a `tool_result` and a `tool_use` input carrying an email is masked everywhere, and a local one is byte-identical.
- Presidio down: a cloud request is refused, a local request passes.
- An image/document/audio block to a cloud alias is refused; to a local alias it passes.
- An email straddling a chunk boundary is still masked.
- A key without a team (or the master key) gets names masked too; a team renamed in `teams.yaml` but not in the policy fails `make test`.
- `vector_store_ids` on a cloud request is refused.

---

## File Structure

- `litellm/pii_policy.yaml` (create): the policy data.
- `litellm/pii_policy.py` (create): pure `load_policy`, `decide`, `entities_for`, `chunk_text`. No LiteLLM import.
- `litellm/cloud_pii.py` (create): the `CloudPII` guardrail (imports LiteLLM and `pii_policy`).
- `scripts/test_pii_policy.py` (create): policy, chunking and consistency tests (stdlib + PyYAML).
- `scripts/test_cloud_pii.py` (create): guardrail tests against a stub Presidio (needs `litellm`).
- `litellm/config.yaml`, `docker-compose.platform.yml`, `scripts/test.sh`, `CLAUDE.md`, `README.md` (modify).

### Task 1: Policy data and pure decisions

**Files:**
- Create: `litellm/pii_policy.yaml`, `litellm/pii_policy.py`, `scripts/test_pii_policy.py`
- Modify: `scripts/test.sh` (run the new test)

**Interfaces:**
- Produces: `load_policy(path: str) -> dict`; `decide(policy: dict, model: str | None, team: str | None) -> Decision` where `Decision` is a frozen dataclass `(mask: bool, groups: tuple[str, ...])`; `entities_for(policy: dict, groups: tuple[str, ...]) -> list[str]`; `validate(policy: dict, teams: dict, config: dict) -> list[str]` (messages; `teams` is the parsed `teams.yaml`, `config` the parsed `config.yaml`).
- Policy keys: `local_models: [str]`, `groups: {identifiants: {entities: [str], thresholds: {str: float}}, noms: {entities: [str], languages: [str]}}`, `teams: {alias: [group]}`, `default: [group]`.

- [ ] **Step 1: Write failing tests** in `scripts/test_pii_policy.py` (plain asserts, `__main__` runner like `scripts/test_litellm_provision.py`): `test_local_alias_is_not_masked` (`decide(P, "qwen3.8:27b-mlx", "apps").mask is False`), `test_unknown_alias_is_masked` (`"gpt-x"`, and `None`), `test_cloud_alias_uses_team_groups` (`dev-sessions` → `("identifiants",)`, `famille` → `("identifiants","noms")`), `test_no_team_gets_strictest` (`team=None` → both groups), `test_unknown_team_gets_default`, `test_entities_for_names_is_person_only`, `test_validate_rejects_team_missing_from_teams_yaml`, `test_validate_rejects_local_model_not_in_config`, `test_validate_rejects_local_model_on_a_provider` (a `local_models` entry whose `model_list` entry starts `anthropic/`, `gemini/` or `openai/`), `test_repo_policy_is_consistent` (real files, `validate(...) == []`).
- [ ] **Step 2: Run** `uv run -q --no-project --with pyyaml python scripts/test_pii_policy.py`. Expected: FAIL, module missing.
- [ ] **Step 3: Implement** the four functions in `litellm/pii_policy.py` (stdlib + `yaml`; `sys.path` import from the tests by file location). Write `litellm/pii_policy.yaml` with the Global Constraints values.
- [ ] **Step 4: Add the test to `scripts/test.sh`** in the unit section, same `pass`/`fail` form as the provisioning test.
- [ ] **Step 5: Run the test and `bash -n scripts/test.sh`.** Expected: all `ok`.
- [ ] **Step 6: Commit** `feat(litellm): PII policy data and pure decisions`.

### Task 2: Chunking

**Files:**
- Modify: `litellm/pii_policy.py`, `scripts/test_pii_policy.py`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `chunk_text(text: str, max_chars: int = 100_000, overlap: int = 200) -> list[tuple[int, int]]` returning `(start, end)` offsets that cover the whole text, cut at the last newline before `max_chars` when one exists, each chunk (after the first) starting `overlap` characters before the previous end.

- [ ] **Step 1: Write failing tests:** `test_short_text_is_one_chunk`, `test_chunks_cover_the_whole_text`, `test_chunks_cut_at_line_ends_when_possible`, `test_email_across_a_boundary_lies_whole_inside_one_chunk` (an email placed to straddle `max_chars=50` with `overlap=20` is contained entirely in at least one chunk).
- [ ] **Step 2: Run the test file.** Expected: the four new tests FAIL.
- [ ] **Step 3: Implement `chunk_text`** in `litellm/pii_policy.py`.
- [ ] **Step 4: Run the test file.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(litellm): chunk long text for PII scanning`.

### Task 3: The guardrail

**Files:**
- Create: `litellm/cloud_pii.py`, `scripts/test_cloud_pii.py`
- Modify: `scripts/test.sh` (run it with the pinned LiteLLM)

**Interfaces:**
- Consumes: `load_policy`, `decide`, `entities_for`, `chunk_text`, `Decision` (Tasks 1-2).
- Produces: `class CloudPII(_OPTIONAL_PresidioPIIMasking)` (from `litellm.proxy.guardrails.guardrail_hooks.presidio`) constructed as `CloudPII(policy_path: str, **kwargs)`, with `async def apply_guardrail(self, inputs, request_data, input_type, logging_obj=None)`; raises `fastapi.HTTPException(status_code=400)` for a refusal and a 5xx-class exception for Presidio failure.
- Guardrail config: `guardrail: cloud_pii.CloudPII`, `mode: pre_call`, `default_on: true`, `policy_path: /app/pii_policy.yaml`.

- [ ] **Step 1: Spike first (not committed).** In a scratch directory, run the pinned LiteLLM locally (`uv run --with "litellm[proxy]==<tag>"`) with a stub Presidio and a mock model, and find out, for `/v1/chat/completions` and `/v1/messages`: which hook the framework calls on a `CloudPII` subclass (`apply_guardrail`, the inherited `async_pre_call_hook`, or both), what `request_data` carries for the team (`user_api_key_team_alias` and where), what `inputs["texts"]`/`["images"]`/`["structured_messages"]` hold for `system`, `tool_result` and `tool_use`, and where `vector_store_ids` appears. Record each answer as a one-line ledger ruling; later steps use them. The inherited `async_pre_call_hook` must never mask local traffic: override it as needed so each request is masked at most once.
- [ ] **Step 2: Write failing tests** in `scripts/test_cloud_pii.py` against a stdlib stub HTTP server standing in for `/analyze` and `/anonymize` (it recognises emails and the name `Marie Tremblay`), calling `apply_guardrail` directly with synthetic `inputs`/`request_data`: `test_local_alias_passes_untouched_without_calling_presidio`, `test_cloud_alias_masks_identifiers`, `test_cloud_alias_masks_names_for_famille_not_dev_sessions`, `test_unknown_alias_is_masked`, `test_no_team_masks_names`, `test_presidio_down_refuses_cloud_and_passes_local`, `test_image_block_refused_for_cloud_passes_for_local`, `test_unknown_block_type_refused_for_cloud`, `test_long_text_with_email_on_chunk_boundary_is_masked`, `test_vector_store_ids_on_cloud_request_refused`, `test_tool_result_and_tool_use_text_are_masked`, `test_response_input_type_is_left_alone`.
- [ ] **Step 3: Run** (`uv run -q --no-project --with pyyaml --with "litellm[proxy]==<tag>" python scripts/test_cloud_pii.py`). Expected: FAIL, module missing.
- [ ] **Step 4: Implement `CloudPII`** in `litellm/cloud_pii.py`: decide per request from `inputs["model"]` (fall back to `request_data["model"]`) and the team; local → return `inputs`; otherwise refuse images/unknown blocks and `vector_store_ids`/`file_search`, then mask each text in chunks with the group's entities and thresholds (two language passes for `noms`), reusing the inherited Presidio call rather than rewriting it; any Presidio error or timeout raises.
- [ ] **Step 5: Add to `scripts/test.sh`:** read the LiteLLM version from the `litellm-database:v...-stable` tag in `docker-compose.platform.yml` (as the prefect version is read) and run the test with it, reported through `pass`/`fail`.
- [ ] **Step 6: Run the test and `bash -n scripts/test.sh`.** Expected: PASS.
- [ ] **Step 7: Commit** `feat(litellm): cloud-pii guardrail`.

### Task 4: Wire it in, guard it, document it

**Files:**
- Modify: `litellm/config.yaml`, `docker-compose.platform.yml`, `scripts/test_pii_policy.py`, `scripts/test.sh` (if needed), `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: the guardrail config line from Task 3 and `validate` from Task 1.

- [ ] **Step 1: Write failing tests** in `scripts/test_pii_policy.py`: `test_cloud_pii_is_the_only_default_on_guardrail` (parse `config.yaml`: exactly one guardrail with `default_on: true`, named `cloud-pii`), `test_old_pii_guardrails_are_gone` (no `pii-identifiants`, `pii-noms-fr`, `pii-noms-en`), `test_no_fallbacks_configured` (no `fallbacks` key under `router_settings` or `litellm_settings`), `test_compose_mounts_the_guardrail_files` (the `litellm` service mounts `cloud_pii.py`, `pii_policy.py` and `pii_policy.yaml` read-only under `/app/`).
- [ ] **Step 2: Run the test file.** Expected: the four new tests FAIL.
- [ ] **Step 3: Implement.** In `config.yaml` replace the three Presidio guardrails with `cloud-pii` (settings from Task 3, `policy_path` under `/app/`), keeping the comment that explains the French identifiers and the fail-closed behaviour, updated for the new rule; in the compose `litellm` service add the three read-only bind mounts (`${INFRA_DIR:-.}/litellm/...`).
- [ ] **Step 4: Documentation.** Update the `presidio-*` and `litellm` entries in `CLAUDE.md` (what masks, when, per team; the inverted rule; that a UI-added model is masked; the cloud + `second-brain` refusal and the live-verification gate to remove it) and add a short README section with the live checklist: a local request arrives intact, a cloud request arrives masked, an image to a cloud alias is refused, the Presidio-down case, and the `second-brain` check that would allow lifting the refusal.
- [ ] **Step 5: Run the policy and guardrail tests, then `bash -n scripts/test.sh`.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(litellm): swap Presidio guardrails for cloud-pii`.
