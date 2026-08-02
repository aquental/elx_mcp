# Review: ElxMCP MVP (MCP Project Status Server)

**Date**: 2026-08-01  
**Files Reviewed**: ~50 new modules (greenfield; no commits)  
**Reviewers**: elixir-reviewer, iron-law-judge, security-analyzer, testing-reviewer, requirements-verifier  
**Consolidated**: `.claude/plans/elx-mcp-mvp/summaries/review-consolidated.md`

## Summary

| Severity | Count |
|----------|------:|
| Blockers (test coverage) | 5 |
| Warnings | ~19 unique |
| Suggestions | compressed groups |
| Iron Law violations | **0** |

**Verdict**: **REQUIRES CHANGES**

- Not Iron-Law **BLOCKED** (0 violations).
- Test coverage gaps on public APIs → **REQUIRES CHANGES**.
- Requirements: 1 **PARTIAL** (missing sprints resource) → would alone be PASS WITH WARNINGS; combined with test gaps → REQUIRES CHANGES.

---

## Requirements Coverage (from SPEC v0.2 + plan elx-mcp-mvp)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | 13 domain tables on Postgres `hermes` | MET | migration + config host |
| 2 | Jira `{KEY}-{N}` issue counter | MET | `Tenancy.next_issue_key/1` |
| 3 | Story w/o epic OK; ticket needs story | MET | schemas + tests |
| 4 | Subtasks + cycle validation | MET | code present; cycle path undertested |
| 5 | API key 32B + SHA-256 + mix task | MET | `Auth` + `GenApiKey` |
| 6 | Multi-key / revoke / no expiry | MET | auth tests |
| 7 | Anubis `/mcp` Streamable HTTP | MET | router + application |
| 8 | Read tools + resources + X-API-Key | **PARTIAL** | 12 tools + 4 resources; **missing** `project://sprints/{id_or_name}` |
| 9 | `project_status` counts + N recent | MET | tools + projects |
| 10 | Key sees whole project | MET | scope filters |
| 11 | Bilingual tool docs | MET | moduledocs |
| 12 | CORS configurable | MET | plug + config |
| 13 | Telemetry on tools | MET | `Helpers.emit_tool` |
| 14 | Seeds demo data | MET | `seeds.exs` |
| 15 | Core auth/isolation tests | MET | suite exists |
| 16 | `mix precommit` clean | UNCLEAR | alias exists; review did not re-run (session earlier: 26 pass) |

**Summary**: **13 MET · 1 PARTIAL · 0 UNMET · 1 UNCLEAR**

---

## Blockers (5) — test coverage

### 1. Projects public API largely untested

**File**: `lib/elx_mcp/projects.ex`  
**Reviewer**: testing-reviewer  
**Issue**: Boards, sprints, components, epic list/get, ticket filters, `search_work_items`, and parent **cycle** path have little or no coverage.  
**Why this matters**: Regressions in multi-tenant listing/search will ship unnoticed.  
**Recommendation**: `describe` per entity + cycle + search + filters.

### 2. MCP tools/resources almost untested

**File**: `test/elx_mcp/mcp/tools_test.exs`  
**Reviewer**: testing-reviewer  
**Issue**: Only `ProjectStatus`, `ListEpics`, unauthorized frame. **10/12 tools** and **0/4 resources** untested (including not-found).  
**Why this matters**: MCP is the product surface.  
**Recommendation**: Unit-test each tool/resource with `Frame` assigns; assert JSON content.

### 3. No authenticated E2E `/mcp`

**File**: `test/elx_mcp_web/plugs/mcp_auth_test.exs`  
**Reviewer**: testing-reviewer  
**Issue**: Valid key only exercises `MCPAuth.call/2` in isolation; never full Anubis StreamableHTTP with assigns → tool.  
**Recommendation**: Supervised server + ConnCase initialize/tools/call (or document unit-only strategy).

### 4. Auth scope gate untested

**File**: `lib/elx_mcp/auth.ex`  
**Reviewer**: testing-reviewer  
**Issue**: Key without `"project:read"` not asserted unauthorized; non-binary verify; `get_api_key!` untested.  
**Recommendation**: Add negative scope test.

### 5. Collaboration isolation + attachment gap

**File**: `lib/elx_mcp/collaboration.ex`  
**Reviewer**: testing-reviewer  
**Issue**: No `create_attachment` tests; no cross-tenant list isolation for comments/changelog; weak worklog cases.  
**Recommendation**: Mirror projects isolation tests for collab lists.

---

## Warnings (selected high-impact)

### 1. Preloaded associations dropped from MCP JSON

**File**: `lib/elx_mcp/mcp/helpers.ex` (~52)  
**Reviewer**: elixir-reviewer  
**Issue**: `encode_struct/1` drops `:tickets`, `:user_stories`, `:subtasks`, etc. after preload.  
**Recommendation**: Encode nested summaries or stop preloading.

### 2. Invalid story/epic key → silent empty list

**File**: `list_tickets.ex` / `list_user_stories.ex`  
**Reviewer**: elixir-reviewer  
**Issue**: Missing parent injects random UUID → `[]` instead of not-found.  
**Recommendation**: `error_reply` on not-found.

### 3. No same-tenant FK integrity on creates

**File**: `projects.ex` + migration  
**Reviewers**: elixir-reviewer, security-analyzer  
**Issue**: FK existence ≠ same `project_id`. Safe while writes are trusted; hole for future write tools.  
**Recommendation**: Validate associations under `project_id` / pass `%Scope{}` to mutations.

### 4. Worklog `time_spent_seconds` race

**File**: `collaboration.ex`  
**Reviewer**: elixir-reviewer  
**Issue**: Non-atomic read-modify-write.  
**Recommendation**: `FOR UPDATE` or `update_all(inc: ...)`.

### 5. Unbounded list queries (boards/sprints/comments)

**File**: `projects.ex`, `collaboration.ex`  
**Reviewer**: elixir-reviewer  
**Recommendation**: Default/max `limit` like tickets.

### 6. Plaintext API key in Anubis `frame.context.headers`

**File**: Anubis StreamableHTTP (deps) + session  
**Reviewer**: security-analyzer  
**Issue**: Full `x-api-key` available in frame context memory.  
**Recommendation**: Avoid logging frame; strip header if customizable; never log context.

### 7. No rate limiting on `/mcp` + `last_used_at` write every request

**File**: `auth.ex`, router  
**Reviewer**: security-analyzer  
**Recommendation**: IP rate limit; debounce `touch_last_used`.

### 8. CORS `*` in non-prod; scopes not allowlisted; helpers default scopes

**Files**: config, `cors.ex`, `helpers.ex`, `api_key`  
**Reviewers**: security-analyzer, elixir-reviewer  
**Recommendation**: Fail closed on missing scopes; `validate_subset` scopes; refuse `*` in prod.

### 9. Body parsed before auth

**File**: `endpoint.ex`  
**Reviewer**: security-analyzer  
**Recommendation**: Body size limits / edge controls for `/mcp`.

---

## Suggestions (compressed)

- Issue key gaps on failed insert (acceptable Jira-like).
- Search/status_summary query cost / indexes later.
- Factories + stronger tool JSON asserts.
- Mix task key in shell history / CI log hygiene.
- Optional: `serialize_assigns/1`, SSE subscriber tenant metadata, Postgres SSL in prod.

---

## Iron Laws

**0 violations.** Mix task correctly uses `app.config` + `ensure_all_started`. Queries pin with `^`. No `String.to_atom` on input.

---

## Next Steps

How would you like to proceed?

- **`/phx:triage`** (recommended) — prioritize which findings to fix  
- **`/phx:plan .claude/plans/elx-mcp-mvp/reviews/elx-mcp-mvp-review.md`** — convert findings into a fix plan  
- **`/phx:work`** — fix directly once prioritized  
- **I'll handle it myself**

Any findings to suppress or enforce as conventions?

---

## At-a-glance

| # | Finding | Severity | Reviewer | File | New? |
|---|---------|----------|----------|------|------|
| 1 | Projects API coverage gaps | BLOCKER (tests) | testing | `projects.ex` | Yes |
| 2 | MCP tools/resources coverage | BLOCKER (tests) | testing | `tools_test.exs` | Yes |
| 3 | No E2E `/mcp` auth→tool | BLOCKER (tests) | testing | `mcp_auth_test.exs` | Yes |
| 4 | Scope deny untested | BLOCKER (tests) | testing | `auth.ex` | Yes |
| 5 | Collaboration isolation/attachment | BLOCKER (tests) | testing | `collaboration.ex` | Yes |
| 6 | encode_struct drops preloads | WARNING | elixir | `helpers.ex` | Yes |
| 7 | Silent empty on bad story/epic key | WARNING | elixir | list tools | Yes |
| 8 | Cross-tenant FK integrity | WARNING | elixir+security | creates | Yes |
| 9 | Worklog race | WARNING | elixir | `collaboration.ex` | Yes |
| 10 | Unbounded lists | WARNING | elixir | list_* | Yes |
| 11 | Key in frame.context.headers | WARNING | security | Anubis/HTTP | Yes |
| 12 | No rate limit / last_used amp | WARNING | security | `/mcp` | Yes |
| 13 | CORS * / scopes defaults | WARNING | security | config/helpers | Yes |
| 14 | Missing sprints resource | PARTIAL req | requirements | `mcp/server.ex` | Yes |
| 15 | Iron Laws | PASS | iron-law-judge | — | Yes |
