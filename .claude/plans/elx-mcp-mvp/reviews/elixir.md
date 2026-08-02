# Code Review: ElxMCP MVP (Elixir/Phoenix)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 14 (0 BLOCKER, 8 WARNING, 6 SUGGESTION)
- **Scope**: New multi-tenant domain, Auth/Scope, MCP tools/resources, plugs, migration, mix task
- **Stock Phoenix** (endpoint/layouts/page): no material issues for this MVP

Read paths correctly pin `project_id` via `%Scope{}`. API keys are high-entropy SHA-256 hashes. Mix task boots with `app.config` + `ensure_all_started` (correct). No `String.to_atom/1`, money floats, or bare rescues in new code.

---

## WARNING

### 1. `lib/elx_mcp/mcp/helpers.ex:52-67` — Preloaded associations dropped from MCP responses
**Issue:** `encode_struct/1` always drops `:user_stories`, `:tickets`, `:subtasks`, `:worklogs`, `:epic`, `:user_story`, etc.
**Why:** `Projects.get_epic/2`, `get_user_story/2`, and `get_ticket/2` preload those associations, then tools call `Helpers.encode_struct/1` — nested data never reaches the client; preloads are wasted queries.
**Approach:** Either stop preloading, or encode selected associations (e.g. map nested lists through `encode_struct/1` instead of dropping them).

### 2. `lib/elx_mcp/mcp/tools/list_tickets.ex:40-45` / `list_user_stories.ex:38-42` — Silent empty filter on missing parent key
**Issue:** Invalid `story_key` / `epic_key` injects `Ecto.UUID.generate()` so the query returns `[]` instead of not-found.
**Why:** Callers cannot distinguish “no tickets” from “story does not exist”; masks typos and confuses agents.
**Approach:** Return `Helpers.error_reply(frame, ...)` on `{:error, :not_found}` (same pattern as `list_comments`).

### 3. `lib/elx_mcp/projects.ex` + schemas — No same-tenant checks on associations
**Issue:** `create_ticket/2` (and story/sprint creates) accept `user_story_id`, `parent_ticket_id`, `board_id`, `sprint_id` without verifying they belong to `project_id`. DB FKs only enforce row existence, not tenant match.
**Why:** Cross-project links are possible via seeds/admin/future write APIs — multi-tenant integrity hole.
**Approach:** Validate each FK with `Repo.get_by(Schema, id: id, project_id: project_id)` (or composite DB constraints / exclusion of cross-tenant parents). Prefer not casting `project_id` from external attrs (set via `Ecto.Changeset.put_change/3`).

### 4. `lib/elx_mcp/collaboration.ex:46-52` — Non-atomic `time_spent_seconds` update
**Issue:** Worklog Multi reads ticket then writes `time_spent + delta` without row lock / `update_all(inc: ...)`.
**Why:** Concurrent worklogs lose updates (last write wins).
**Approach:** `lock("FOR UPDATE")` on the ticket row inside Multi, or `update_all([inc: [time_spent_seconds: worklog.time_spent_seconds]], ...)`.

### 5. `lib/elx_mcp/projects.ex:31-38`, `list_boards`, `Collaboration.list_comments` — Unbounded list queries
**Issue:** `list_sprints/2`, `list_boards/1`, `list_comments/3` have no `limit`; MCP `ListSprints` / `ListBoards` pass none.
**Why:** Large tenants can return huge JSON payloads over MCP (memory / timeout risk).
**Approach:** Default + max cap (e.g. 50/100) in context helpers; wire tool schema `limit` like list tickets.

### 6. `lib/elx_mcp/auth/api_key.ex:28` / create paths — `project_id` (and issue `key`) in `cast/3`
**Issue:** Programmatic tenant/key fields are castable from attrs maps.
**Why:** Phoenix/Ecto convention: never cast fields set by the server; reduces mass-assignment risk when attrs become external.
**Approach:** Drop `:project_id` / `:key` / `:key_hash` from cast; set with `put_change/3` in context functions after trust boundary.

### 7. `lib/elx_mcp/auth.ex:27` / `api_key.ex` — Scopes not allowlisted
**Issue:** Arbitrary scope strings can be stored; only `"project:read"` is checked at verify.
**Why:** Future scopes become ambient data with no validation; easy to invent meaningless or privileged labels.
**Approach:** `validate_subset(:scopes, ~w(project:read ...))` (or Catalog helper).

### 8. `lib/elx_mcp/mcp/helpers.ex:7-21` — Rebuilds Scope; ignores `current_scope`
**Issue:** Plug assigns `%Scope{}` as `:current_scope`, but helpers reconstruct from partial assigns and default `scopes` to `["project:read"]` if missing.
**Why:** Drift risk if assigns evolve; default scopes can paper over incomplete assigns.
**Approach:** Prefer `frame.assigns[:current_scope]`; fail closed if absent (no default scopes).

---

## SUGGESTION

### 1. `lib/elx_mcp/projects.ex:49-60` — Issue key burned on failed insert
`next_issue_key/1` commits counter before insert; failed changeset leaves gaps. Acceptable for Jira-like keys, or wrap counter+insert in one transaction and only bump after successful insert.

### 2. `lib/elx_mcp/projects.ex:162-199` — Search fairness / cost
Three independent `limit: n` queries then `Enum.take/2` can bias type mix and always run 3 ILIKEs. Consider union query or per-type quotas; add trigram/GIN indexes if search is hot.

### 3. `lib/elx_mcp/projects.ex:205-238` — `status_summary/2` query fan-out
Multiple count + list queries per call. Fine for MVP; later aggregate with fewer round-trips.

### 4. `lib/elx_mcp/auth.ex:90-94` — `touch_last_used` every verify
Best-effort `update_all` on every MCP request adds write load. Debounce (e.g. only if `last_used_at` older than N minutes) or async.

### 5. Tests — Thin MCP/auth integration surface
`tools_test` builds `Frame` manually; plug test does not exercise full Anubis `/mcp` JSON-RPC with a valid key. Add one end-to-end conn test that auth assigns flow into a tool reply.

### 6. `lib/elx_mcp/mcp/helpers.ex:24-31` — Scope check without `Scope.has_scope?/2`
`has_scope?/2` is unused; verify-time `"project:read"` is the only gate. When scopes expand, re-check in `with_scope/2`.

---

## Notes (non-issues for this pass)
- Tenant **read** isolation via `where: project_id == ^scope.project_id` looks correct (covered by `projects_test` cross-tenant case).
- API key: 32-byte entropy + SHA-256 store + hex validate is sound for bearer secrets.
- CORS OPTIONS bypass of MCPAuth is correct; prod origins from `MCP_CORS_ORIGINS`.
- Migration is cohesive and mostly indexed appropriately for list-by-status / FK paths.
- Stock Phoenix files: no review findings required for MVP MCP path.
