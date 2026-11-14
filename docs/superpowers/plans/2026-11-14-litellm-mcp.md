# LiteLLM MCP tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Obsidian (read-only) and GitHub (level 2: propose, never merge) as MCP servers behind LiteLLM, with per-team access enforced by the existing `cloud_pii` gate.

**Architecture:** A new `mcp` stack runs two servers on `infra-net`: the official `github/github-mcp-server` (HTTP, `--tools` allowlist) and a small read-only Obsidian server over S3 built from `mcp/obsidian/`. LiteLLM registers both in `mcp_servers:`; the gate gets a `call_mcp_tool` branch that decides by the authenticated key's team from a versioned policy file, and guards GitHub writes to default branches.

**Tech Stack:** Python 3.12, `uv`, the `mcp` Python SDK, `boto3`, LiteLLM `v1.83.14-stable`, Docker Compose, Portainer stacks.

**Spec:** `docs/superpowers/specs/2026-11-14-litellm-mcp-design.md`

## Global Constraints

- GitHub level 2 only: tools may read, and may write issues, comments, branches, file commits, and open or update PRs. **`merge_pull_request` is in no list.** Also excluded: create/delete/fork repository, delete file, run workflow, rulesets and custom properties, approving a review, notifications, gists, projects, security alerts.
- The GitHub tool list is an **allowlist** and exists three times: the server's `--tools`, LiteLLM's `allowed_tools`, and `litellm/mcp_policy.yaml`; a `make test` case fails if they differ or if `merge_pull_request` is present.
- Access: Obsidian for `admin` and `apps`; GitHub for `admin`; `famille`, `dev-sessions`, a key with no team and the master key get no MCP tool. Decided by the authenticated key's `team_id`, in the gate.
- A tool whose server prefix is not in the policy is refused.
- Gate: `create_or_update_file` and `push_files` without `branch`, or with `branch` `main` or `master`, are refused.
- Obsidian server: read-only by construction (S3 identity `Read,List` only, no put/delete code), only `.md` files, never under `.obsidian/`, path normalised (no `..`, no leading `/`), reads capped at 1 MiB, search bounded, listing shows current versions only; it requires `Authorization: Bearer $OBSIDIAN_MCP_TOKEN`.
- Stack `mcp` on the homelab (`-` in `stacks.conf`), no `ports:`, no NGINX vhost, every image pinned `tag@sha256` (the local Obsidian image by tag, built by `make app-images`, `pull_policy: never`).
- Secrets `GITHUB_MCP_TOKEN`, `OBSIDIAN_MCP_TOKEN`, `OBSIDIAN_MCP_S3_SECRET_KEY` are flat `.env` keys (vault), in `.env.example`, required by `check-env`; never in the repo or a log. The GitHub token never has `Administration`, `Workflows` or `Actions` write.
- MCP arguments are not masked; results are masked toward cloud models by the existing gate. The PII gate must not refuse an allowed MCP call.
- Out of scope: Portainer MCP, Obsidian writes or attachments, LiteLLM-native `object_permission` (the gate is the source of truth), cost per tool.

## Review Focus

- A team absent from the policy, a key with no team and the master key cannot call any MCP tool; `admin` reaches both servers, `apps` only Obsidian.
- `merge_pull_request` cannot be called through any layer.
- A GitHub file write to `main`, `master` or with no branch is refused.
- Obsidian: `../etc`, `/abs`, `.obsidian/x.md`, `x.png`, and a file over 1 MiB are refused or invisible; a missing or wrong token is rejected.
- A tool from an unregistered server prefix is refused; an allowed MCP call is not refused by the PII gate, and non-MCP traffic behaves exactly as before.

---

## File Structure

- `litellm/mcp_policy.yaml`, `litellm/mcp_policy.py` (create): the access policy and its pure decisions.
- `litellm/cloud_pii.py` (modify): the `call_mcp_tool` branch.
- `mcp/obsidian/` (create): `notes.py` (pure and S3-backed note logic), `server.py` (MCP wiring and token check), `Dockerfile`, pinned `requirements.txt`.
- `docker-compose.mcp.yml`, `stacks.conf` (create/modify): the stack.
- `litellm/config.yaml`, `docker-compose.platform.yml` (modify): `mcp_servers:`, mounts, env.
- `.env.example`, `scripts/check-env.sh`, `scripts/provision-s3.sh`, `scripts/portainer-images.sh`, `Makefile`, `scripts/test.sh`, `CLAUDE.md`, `README.md` (modify).
- `scripts/test_mcp_policy.py`, `scripts/test_mcp_obsidian.py` (create): plain-assert tests.

### Task 1: Access policy and the gate's MCP branch

**Files:**
- Create: `litellm/mcp_policy.yaml`, `litellm/mcp_policy.py`, `scripts/test_mcp_policy.py`
- Modify: `litellm/cloud_pii.py`, `scripts/test_cloud_pii.py`, `scripts/test.sh`

**Interfaces:**
- Produces: `load_policy(path: str) -> dict`; `server_of(policy: dict, tool_name: str) -> str | None` (the registered server alias whose prefix starts the tool name, longest match); `refusal(policy: dict, team_id: str | None, tool_name: str | None, arguments: dict | None) -> str | None` (a reason, or `None` when allowed).
- Policy keys: `separator: str` (between server alias and tool name), `servers: {alias: [team_id]}`, `github_tools: [str]`, `branch_guard: {tools: [str], refuse_branches: [str]}`.
- `cloud_pii.CloudPIIGate` gets `mcp_policy_path` (env `MCP_POLICY_PATH`, default `/app/mcp_policy.yaml`) and a branch for `call_type == "call_mcp_tool"` that reads `data["mcp_tool_name"]`, `data["mcp_arguments"]` and the team from `user_api_key_dict.team_id`, raises `HTTPException(403)` on a reason, otherwise returns `data` untouched.

- [ ] **Step 1: Spike first (not committed).** Run the pinned LiteLLM locally (`uv run --with "litellm[proxy]==<tag>"`, the way the PII work did) with two stub MCP servers named `obsidian` and `github`, and find out: the exact separator LiteLLM puts between server alias and tool name, the `call_type` and `data` keys the gate sees for a tool call **and for the tools list**, the team field on `user_api_key_dict`, and what LiteLLM does at startup when a server is down. Record each answer as a one-line ledger ruling; the policy `separator` and the list-call handling follow from them. If the gate does not see tool calls at all, stop and report.
- [ ] **Step 2: Write failing tests** in `scripts/test_mcp_policy.py` (`__main__` runner as in `scripts/test_pii_policy.py`): `test_admin_reaches_both_servers`, `test_apps_reaches_obsidian_only`, `test_famille_and_dev_sessions_get_nothing`, `test_no_team_and_master_key_get_nothing` (`team_id=None`), `test_unregistered_prefix_is_refused`, `test_merge_pull_request_is_in_no_list` (policy `github_tools`), `test_github_write_without_a_branch_is_refused`, `test_github_write_to_main_or_master_is_refused`, `test_github_write_to_a_feature_branch_passes`, `test_policy_teams_exist_in_teams_yaml`, `test_policy_servers_are_registered_in_config_yaml` (real `config.yaml` once Task 4 adds `mcp_servers:`; until then skip with a clear message). In `scripts/test_cloud_pii.py` add `test_mcp_call_is_allowed_for_a_team_with_access`, `test_mcp_call_is_refused_for_another_team_with_403`, `test_mcp_call_without_a_team_is_refused`, `test_mcp_arguments_are_not_masked`, `test_a_tools_list_call_is_not_refused` (per the spike), and that existing non-MCP tests are unchanged.
- [ ] **Step 3: Run both test files.** Expected: the new tests FAIL.
- [ ] **Step 4: Implement** `mcp_policy.py`, write `mcp_policy.yaml` with the Global Constraints values (`github_tools` filled in Task 4 once the pinned server's tool names are known: start with the read tools and the level-2 write tools named in the spec), and add the gate branch before the `decide(...)` call. Add both test files to `scripts/test.sh` in the unit section.
- [ ] **Step 5: Run the tests and `bash -n scripts/test.sh`.** Expected: PASS, and the earlier gate tests still pass.
- [ ] **Step 6: Commit** `feat(litellm): MCP access policy and gate branch`.

### Task 2: The Obsidian MCP server

**Files:**
- Create: `mcp/obsidian/notes.py`, `mcp/obsidian/server.py`, `mcp/obsidian/Dockerfile`, `mcp/obsidian/requirements.txt`, `scripts/test_mcp_obsidian.py`
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces in `notes.py`: `normalize_path(path: str) -> str` (raises `ValueError`), `is_note_key(key: str) -> bool`, `list_notes(s3, bucket: str, prefix: str = "", limit: int = 200) -> list[str]`, `read_note(s3, bucket: str, path: str) -> str`, `search_notes(s3, bucket: str, query: str, prefix: str = "", limit: int = 20) -> list[dict]` (`{"path", "snippet"}`), constants `MAX_READ_BYTES = 1_048_576`, `MAX_SCAN_OBJECTS`, `SNIPPET_CHARS`. `s3` is a boto3-style client.
- `server.py` exposes MCP tools `list_notes`, `read_note`, `search_notes` over streamable HTTP and rejects any request without `Authorization: Bearer $OBSIDIAN_MCP_TOKEN`.

- [ ] **Step 1: Write failing tests** in `scripts/test_mcp_obsidian.py` against a stdlib stub S3 (ListObjectsV2 and GetObject, no signature check) holding notes, a `.obsidian/app.json`, a `photo.png` and a 2 MiB note: `test_normalize_rejects_parent_traversal_and_absolute_paths`, `test_normalize_strips_nothing_inside_the_vault`, `test_only_md_files_are_notes`, `test_obsidian_folder_is_invisible_to_list_and_search`, `test_list_notes_honours_prefix_and_limit`, `test_read_note_returns_text`, `test_read_note_over_one_mib_is_refused`, `test_read_note_outside_the_rules_is_refused` (`.obsidian/x.md`, `x.png`, `../x.md`), `test_search_returns_bounded_snippets_and_stops_at_the_limit`, `test_search_stops_after_max_scan_objects`, `test_notes_module_has_no_write_call` (the source contains no `put_object`, `delete_object`, `copy_object`), `test_server_rejects_a_missing_or_wrong_token`, `test_server_accepts_the_right_token_and_lists_the_three_tools`.
- [ ] **Step 2: Run** `uv run -q --no-project --with pyyaml --with boto3==<pin> --with mcp==<pin> python scripts/test_mcp_obsidian.py`. Expected: FAIL, module missing.
- [ ] **Step 3: Implement** `notes.py` and `server.py`; pin exact versions in `requirements.txt` (the current ones); a small `Dockerfile` (slim Python base pinned by digest, non-root user, installs `requirements.txt`, runs `server.py`; reads `OBSIDIAN_BUCKET`, `OBSIDIAN_VAULT_PREFIX`, `S3_ENDPOINT`, `OBSIDIAN_MCP_S3_ACCESS_KEY`/`OBSIDIAN_MCP_S3_SECRET_KEY`, `OBSIDIAN_MCP_TOKEN`).
- [ ] **Step 4: Add the test to `scripts/test.sh`** (same `pass`/`fail` form, with the pinned `--with` versions read from `mcp/obsidian/requirements.txt`).
- [ ] **Step 5: Run the test and `bash -n scripts/test.sh`.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(mcp): read-only Obsidian MCP server`.

### Task 3: Secrets and the read-only S3 identity

**Files:**
- Modify: `.env.example`, `scripts/check-env.sh`, `scripts/provision-s3.sh`, `Makefile`, `scripts/test.sh`

**Interfaces:**
- Produces: `.env` keys `GITHUB_MCP_TOKEN`, `OBSIDIAN_MCP_TOKEN`, `OBSIDIAN_MCP_S3_SECRET_KEY`; `scripts/provision-s3.sh <app> [bucket] [versioned] [actions]` with `actions` defaulting to `Read,Write,List,Tagging`; `make s3-provision app=obsidian-mcp bucket=obsidian actions=Read,List`.

- [ ] **Step 1: Write failing checks:** in the check-env rejection cases of `scripts/test.sh` (read the loop first), one case per new key rejecting `change-me` and empty; and a case asserting `provision-s3.sh` rejects an `actions` value outside `Read,Write,List,Tagging` and builds the `-actions` argument from its fourth argument (extend the existing fake-`docker` style test if there is one, else a small `bash` test of the argument validation).
- [ ] **Step 2: Run the new cases.** Expected: FAIL.
- [ ] **Step 3: Implement.** Add the three keys to `.env.example` (one comment line each: where the token comes from, its permissions for GitHub, that the S3 identity is read-only) and to `check-env.sh`'s required list; validate and pass `actions` in `provision-s3.sh` (default unchanged, so existing callers are unaffected); add `actions` to the `s3-provision` Make target. Verify with the same throwaway check-env script used earlier if Docker is down.
- [ ] **Step 4: Run the cases and `bash -n` on the scripts.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(mcp): MCP secrets and a read-only S3 identity`.

### Task 4: The `mcp` stack and the LiteLLM wiring

**Files:**
- Create: `docker-compose.mcp.yml`
- Modify: `stacks.conf`, `litellm/config.yaml`, `docker-compose.platform.yml`, `litellm/mcp_policy.yaml`, `scripts/portainer-images.sh`, `Makefile`, `scripts/test_mcp_policy.py`

**Interfaces:**
- Consumes: the policy file (Task 1), the image sources (Task 2), the secrets (Task 3).
- Produces: services `mcp-github` and `mcp-obsidian` on `infra-net`; `mcp_servers:` entries `obsidian` and `github` in `config.yaml`; image `infra-mcp-obsidian:1`.

- [ ] **Step 1: Write failing tests** in `scripts/test_mcp_policy.py`: `test_the_three_github_tool_lists_are_equal` (compose `mcp-github` `--tools`, config `allowed_tools`, policy `github_tools`) with `merge_pull_request` absent from each; `test_mcp_stack_publishes_no_port_and_pins_images` (no `ports:`; `mcp-github` image has `@sha256:`; `mcp-obsidian` is `infra-mcp-obsidian:<tag>` with `pull_policy: never`); `test_stacks_conf_lists_mcp_on_the_homelab`; `test_litellm_mounts_the_mcp_policy` (the two policy files under `/app`, read-only) and receives `GITHUB_MCP_TOKEN` and `OBSIDIAN_MCP_TOKEN`; `test_obsidian_server_requires_its_token_in_litellm_config` (`auth_type: bearer_token` on both servers); and make the Task 1 skipped tests real.
- [ ] **Step 2: Run the test file.** Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Resolve the pinned GitHub server image and its exact tool names (digest from the registry; `--tools` fails to start on an unknown name, which is the intended tripwire) and fill `github_tools` accordingly, keeping the three lists identical. Write `docker-compose.mcp.yml` (both services on external `infra-net`, `restart: unless-stopped`, healthchecks, secrets by `${NAME:?...}`), add the row to `stacks.conf` (environment `-`, owned paths `mcp/`; ordered before `platform`, per the spike on how LiteLLM treats a missing server), add `mcp_servers:` to `config.yaml` (URLs by service name, `auth_type: bearer_token`, `auth_value: os.environ/...`, `allowed_tools` for GitHub) and the mounts and env to the `litellm` service, and add the Obsidian image build to `portainer-images.sh`'s default list (from `https://github.com/nicolaslallier/Infra.git#main:mcp/obsidian`, tag `infra-mcp-obsidian:1`, with a comment that the tag is bumped by hand when `mcp/obsidian/` changes).
- [ ] **Step 4: Run the test files, `bash -n scripts/test.sh`, and the policy test against the real files.** Expected: PASS.
- [ ] **Step 5: Live check (not committed).** Run the pinned LiteLLM locally with the real `config.yaml` `mcp_servers:` shape pointing at stub MCP servers named `obsidian` and `github`; with a key of each team (a stub auth is enough if the real teams cannot be created without a database, then call the gate directly with synthetic `UserAPIKeyAuth`) confirm: an admin tool call passes, an `apps` GitHub call and a `famille` call are refused 403, a GitHub write to `main` is refused, and a PII-gated cloud chat request still behaves as before. Record the results as ledger lines.
- [ ] **Step 6: Commit** `feat(mcp): the mcp stack and its LiteLLM wiring`.

### Task 5: Documentation and the owner's checklist

**Files:**
- Modify: `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write a failing check** in `scripts/test_mcp_policy.py`: `test_docs_name_the_mcp_stack_and_the_no_merge_rule` (`CLAUDE.md` mentions the `mcp` stack, `merge_pull_request` and `mcp_policy.yaml`; `README.md` has a section titled "LiteLLM: MCP tools").
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the docs.** `CLAUDE.md`: add the `mcp` stack to the stack list and Architecture (what each server is, the no-merge rule and where it is enforced three times, who may call what and that the gate decides, the master key having no MCP tool, the branch guard, the Obsidian server's limits). `README.md`, section "LiteLLM: MCP tools", in the owner's order: (1) before merging, create the three secrets in the vault; (2) create the GitHub token as fine-grained, **only** the repos `gh api repos/nicolaslallier/<repo>/rulesets` shows an active ruleset for (today `Infra`, `Jarvis`, `Moria`, `Glee`), permissions Contents, Issues and Pull requests write plus Metadata read, never Administration, Workflows or Actions write, and not the runner repos `AI`, `EA`, `DarkAngel`, `Heaven` until they are protected; (3) `make s3-provision app=obsidian-mcp bucket=obsidian actions=Read,List` and copy the printed secret to the vault; (4) merge, then `make app-images` and `make up stack=mcp` then `stack=platform`; (5) the live checks: with the `nicolas-admin` key list the tools, read a note, search a note, open a PR on a test branch; with an `apps` key a GitHub call is refused; a write to `main` is refused; a `merge_pull_request` call is not available; and that the master key has no MCP tool (so use `nicolas-admin` in the UI test page).
- [ ] **Step 4: Run the check and `bash -n scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `docs: MCP tools and the owner's checklist`.
