# Test Health Audit: ElxMCP

**Date:** 2026-08-01  
**Scope:** `test/elx_mcp/**`, `test/elx_mcp_web/**` vs public APIs in Auth, Tenancy, Projects, Collaboration, MCP tools/resources  
**Baseline:** 41 tests pass; auth requires email + key  

## Summary

| Metric | Value |
|--------|-------|
| **Test Quality Score** | **60 / 100** |
| Tests | 41 (mostly async + SQL sandbox) |
| Critical gaps | Cycle-detection false test; 5/12 tools untested; 0 resource tests; rate-limit/CORS untested |
| Iron law issues | `PageControllerTest` missing `async: true`; shared ETS rate limiter under async |

Auth + plug email/key coverage is solid. Projects/collaboration cover happy paths and isolation. Quality is dragged down by incomplete tool/resource surface, a misnamed cycle test that never fails, and weak MCP response assertions.

---

## Iron Law Violations

| Law | Finding |
|-----|---------|
| **ASYNC BY DEFAULT** | `test/elx_mcp_web/controllers/page_controller_test.exs` — `use ElxMcpWeb.ConnCase` without `async: true` (no global state). |
| **NO PROCESS.SLEEP** | None found. |
| **SANDBOX** | OK — DataCase/ConnCase use SQL Sandbox. |
| **VERIFY_ON_EXIT / Mox** | N/A (no Mox). |

**Flake risk:** `ElxMcp.Auth.RateLimit` uses a **named ETS table** (`:elx_mcp_rate_limit`). `MCPAuthTest` is `async: true` and always keys on `mcp:<remote_ip>` (typically `127.0.0.1`). Concurrent tests share counters; at default 120/min this is unlikely to 429 today, but it is global mutable state and will flake under higher volume or lower limits.

`ValidationMatrixTest` uses `async: false` with little justification (only reads `Application.get_env`; does not mutate env). Acceptable but serializes unnecessarily.

---

## Public API Coverage Gaps

### `ElxMcp.Auth`

| Function | Coverage |
|----------|----------|
| `create_api_key/3` | Covered (incl. invalid scopes, multi-key) |
| `verify_api_key/2` | Covered (match, mismatch, blank, nil, revoked, no `project:read`) |
| `revoke_api_key/1` | Covered |
| `list_api_keys/1` | Covered (indirect) |
| `get_api_key!/1` | **Missing** |
| `touch_last_used` (via verify) | **Missing** — debounce / `last_used_at` never asserted |
| `Auth.RateLimit.check/2` | **Missing** |
| `Auth.Scope.has_scope?/2` | **Missing** direct unit tests (only via tools/plug) |

### `ElxMcp.Tenancy`

| Function | Coverage |
|----------|----------|
| `create_project/1` | Covered |
| `next_issue_key/1` | Covered |
| `get_project!/1` | Indirect only |
| `list_projects/0` | **Missing** |
| `get_project_by_key/1` | **Missing** (incl. case-normalization) |

### `ElxMcp.Projects`

| Function | Coverage |
|----------|----------|
| Boards/sprints/epics create+list+get | Covered (bundled test) |
| Stories/tickets create, list, get, isolation | Covered |
| `status_summary/2`, `search_work_items/3` | Covered |
| `create_component/2` | **Missing** |
| `get_user_story/2` | **Missing** (context) |
| List filter opts (`status`, `priority`, `assignee_email`, `epic_id`, `sprint_id`, `type`, `limit`) | **Mostly missing** |
| Cross-tenant board/sprint/epic association guards | **Missing** (only foreign story tested) |
| Parent cycle → `{:error, :cycle_detected}` | **False coverage** (see Issues) |

### `ElxMcp.Collaboration`

| Function | Coverage |
|----------|----------|
| comment/changelog create+list, isolation | Covered |
| worklog + ticket time aggregation | Covered |
| `create_attachment/2` | Covered create only |
| Worklog wrong `project_id` / missing ticket | **Missing** |
| Invalid polymorphic types | **Missing** |

### MCP tools (`lib/elx_mcp/mcp/tools/*`)

| Tool | Tested? |
|------|---------|
| `ProjectStatus` | Yes (smoke) |
| `ListEpics`, `GetEpic`, `GetTicket` | Yes (smoke) |
| `ListTickets` | Error path only (`story_key`) |
| `ListBoards`, `SearchWorkItems` | Yes (smoke) |
| `GetUserStory` | **No** |
| `ListUserStories` | **No** |
| `ListSprints` | **No** |
| `ListComments` | **No** |
| `ListChangelog` | **No** |

### MCP resources (`lib/elx_mcp/mcp/resources/*`)

| Resource | Tested? |
|----------|---------|
| `Epic`, `Ticket`, `UserStory`, `Sprint`, `ProjectStatus` | **None** |

### Web plugs

| Module | Coverage |
|--------|----------|
| `MCPAuth` | Strong (401 missing key/email, mismatch, success assigns, OPTIONS, header strip) |
| Rate-limit **429** path | **Missing** |
| `CORS` | **Missing** (allowlist, `*`, OPTIONS 204) |
| Authenticated full `/mcp` pipeline E2E | **Missing** (success path tests plug in isolation only) |

---

## Issues Found

### Critical

- [ ] **`projects_test.exs` ~L107–127 — “detects parent ticket cycle” does not detect a cycle**  
  Builds A → B → C and only asserts `{:ok, _}`. Never exercises update/create that would return `{:error, :cycle_detected}` (e.g. parent chain pointing back to self). **False confidence** on cycle safety.

- [ ] **5 of 12 MCP tools untested** — `GetUserStory`, `ListUserStories`, `ListSprints`, `ListComments`, `ListChangelog` have zero execute tests (including not-found / invalid `entity_type`).

- [ ] **All 5 MCP resources untested** — `read/2` paths for epic/ticket/story/sprint/project_status never run.

- [ ] **Rate limit path untested** — `MCPAuth` returns 429 + `retry-after` on `RateLimit.check` error; no test forces `{:error, :rate_limited}`.

### Warnings

- [ ] **Weak MCP tool assertions** (`tools_test.exs`) — most tests only check `response.isError == false` without decoding JSON body shape/keys. Line ~65 `text =~ "user_story" or text =~ ticket.title` is nearly always true via title alone.

- [ ] **`validation_matrix_test.exs`** — single mega-test; V08/V09/V12/V14 are `function_exported?` / `Code.ensure_loaded?` / doc substring checks, not behavioral. Duplicates tenancy/auth/projects cases. Gaps labeled V10/V11/V15/V17 silently skipped.

- [ ] **`PageControllerTest` missing `async: true`**.

- [ ] **Shared ETS rate limiter + async plug tests** — potential flakes; prefer `async: false` for rate-limit tests or isolate table keys per test.

- [ ] **`Auth.get_api_key!/1`**, **`Tenancy.list_projects/0`**, **`get_project_by_key/1`**, **`Projects.create_component/2`**, **`get_user_story/2`** — public APIs with no dedicated tests.

- [ ] **CORS plug untested** — origin allowlist, star flag, OPTIONS 204.

- [ ] **No factories** (`build`/`insert` helpers) — repeated `Tenancy.create_project` + scope construction; higher drift risk, not an iron-law violation.

### Suggestions

- [ ] Split cycle test: assert `{:error, :cycle_detected}` when parent walk hits self; keep happy-path chain separate.
- [ ] Add one execute test per remaining tool (happy + not-found) and one `read/2` per resource.
- [ ] Assert decoded tool JSON (`Jason.decode!` on content text) for keys/counts, not only `isError`.
- [ ] Unit-test `RateLimit.check/2` with low `:limit` and assert plug 429.
- [ ] Cover list filters (status/assignee/limit) and cross-tenant board/sprint associations.
- [ ] Assert `last_used_at` after successful `verify_api_key`.
- [ ] Convert validation matrix into tagged describe blocks with one criterion per test; drop pure “module loaded” checks or mark as smoke-only.

---

## Score Rationale (60)

| Area | Weight | Score | Notes |
|------|--------|-------|-------|
| Auth (email+key) | 20 | 17 | Solid; missing rate limit + last_used |
| Tenancy / Projects core | 25 | 16 | Happy paths OK; cycle false test; filters/components thin |
| Collaboration | 10 | 8 | Main paths + isolation OK |
| MCP tools/resources | 25 | 10 | ~7/12 tools smoke; 0 resources |
| Web plugs / HTTP | 10 | 6 | MCPAuth good; CORS/429/E2E gaps |
| Test quality hygiene | 10 | 3 | Weak asserts, mega-matrix, missing async, ETS flake risk |

**Priority fix order:** (1) real cycle-detection test, (2) remaining 5 tools + resources, (3) rate-limit 429, (4) tighten tool JSON assertions, (5) CORS + missing context APIs.
