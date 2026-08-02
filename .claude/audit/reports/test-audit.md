# Test Health Audit — ElxMCP
**Date:** 2026-08-02  
**Score:** 72 / 100 (grade C)  
**Baseline:** prior 72/C (same residual gaps; suite still ~45 tests)

## Summary

| Metric | Value |
|--------|-------|
| Test files | **11** (`*_test.exs`) + `test_helper.exs` + 2 support cases |
| Tests (approx) | **45** |
| `async: true` | **8** modules |
| `async: false` | **2** (RateLimit ETS, ValidationMatrix) |
| Missing async | **1** (`PageControllerTest` — no global state) |
| Process.sleep / flaky timers | **None** |
| Mox / `verify_on_exit!` / `defmock` | **None** (not used; no incorrect internal mocks) |
| Factories | **None** — ad-hoc `Tenancy.create_project` + manual `Scope` in every file |
| Cover run | Not executed (no shell); estimate from mapping below |

Core domain (Auth email+key, tenancy keys, Projects cycle/isolation, Collaboration isolation) remains solid. Score is still held by shallow MCP tool assertions, **4/5 resources untested**, and missing Plug **429** integration.

## Score breakdown

| Dimension | Max | Score | Notes |
|-----------|-----|-------|-------|
| Coverage | 30 | **17** | Contexts ~good; 12/12 tools smoke-only; 1/5 resources; no CORS/E2E `/mcp` |
| No flakes | 20 | **16** | No sleep; shared ETS `mcp:<ip>` + `MCPAuthTest async: true` residual flake risk |
| Async | 15 | **13** | 8 true / 2 justified false; `PageControllerTest` omits `async: true` |
| Mox | 15 | **15** | N/A clean — no boundary mocks required; no illegal DB/stdlib mocks |
| Duration | 10 | **9** | Small pure unit/DataCase suite; estimated well under 2 min |
| Error paths | 10 | **6** | Auth/plug 401 strong; tool not-found thin; resource/429/CORS error paths missing |
| **Total** | **100** | **72** | Unchanged vs prior residual |

## Issues found

### P1
- [ ] **4/5 MCP resources untested** — only `Resources.ProjectStatus.read/2` smoke (`tools_test.exs:117–118`). Untested: `Epic`, `UserStory`, `Ticket`, `Sprint` (`read/2` happy + not_found + unauthorized).
- [ ] **MCP tool asserts are smoke-only** — 11× `isError == false`, 3× `isError == true`; almost no decoded JSON keys/counts. `get_ticket` uses `text =~ "user_story" or text =~ ticket.title` (title alone always passes).
- [ ] **Plug 429 path not integration-tested** — `MCPAuth` sends 429 + `retry-after` (`mcp_auth.ex:20–26`); only `RateLimit.check/2` unit tests exist.

### P2
- [ ] **`ListTickets` happy path missing** — only error on bad `story_key`; no context `list_tickets/2` or successful tool list.
- [ ] **Projects public API gaps** — `create_component/2`, list filters (`status`/`type`/`assignee`/`limit`), cross-tenant board/sprint/epic/parent guards, LIKE-escape search.
- [ ] **Auth/Tenancy gaps** — `get_api_key!/1`, `last_used_at` after verify, `list_projects/0`, `get_project_by_key/1`.
- [ ] **CORS plug untested** — matrix only asserts config is a list (`validation_matrix_test.exs:79–80`).
- [ ] **Shared ETS rate limiter + async plug tests** — concurrent `MCPAuthTest` keys `mcp:127.0.0.1`; can spuriously 429 under load.
- [ ] **`PageControllerTest` missing `async: true`**.
- [ ] **No factories** — repeated setup; drift risk across 6 DataCase files.
- [ ] **ListComments / ListChangelog** — no invalid `entity_type` / missing key error tests.
- [ ] **Collaboration error paths** — worklog missing ticket / wrong project; invalid polymorphic types.

### P3
- [ ] **`validation_matrix_test.exs`** — one mega-test; V08/V09/V12/V14 are `function_exported?` / doc substrings; V10/V11/V15/V17 skipped silently; duplicates other files; `async: false` without clear need.
- [ ] **No authenticated full `/mcp` E2E** — success path is plug-unit only (`MCPAuth.call/2`).
- [ ] **Catalog** — pure allowlists; no dedicated tests (low risk).
- [ ] **Helpers/telemetry** — `emit_tool` only `function_exported?`, no `:telemetry.attach` assertion.

## Coverage map

### MCP tools (`lib/elx_mcp/mcp/tools/*`) — 12 modules

| Tool | Coverage |
|------|----------|
| ProjectStatus | Smoke + unauthorized (no assigns / missing `project:read`) |
| ListEpics | Smoke `isError == false` |
| GetEpic | Smoke |
| GetTicket | Smoke + weak content assert |
| ListTickets | **Error only** (bad `story_key`) — no happy list |
| ListBoards | Smoke |
| SearchWorkItems | Smoke |
| GetUserStory | Smoke (bundled) |
| ListUserStories | Smoke (bundled) |
| ListSprints | Smoke (bundled) |
| ListComments | Smoke (bundled) |
| ListChangelog | Smoke (bundled) |

### MCP resources — 5 modules

| Resource | Coverage |
|----------|----------|
| ProjectStatus | Smoke `read/2` + `type == :resource` |
| Epic / UserStory / Ticket / Sprint | **None** |

### Contexts

| Context | Coverage |
|---------|----------|
| Auth | Strong (create/verify/revoke/scopes/email) |
| Auth.RateLimit | Unit only (allow + limited); not via Plug |
| Tenancy | create + issue keys + invalid key; list/by_key missing |
| Projects | Core CRUD/isolation/cycle/status/search; filters/components thin |
| Collaboration | comments/changelog/worklog/attachment + isolation; error paths thin |
| Catalog | Untested (constants) |

### Web

| Area | Coverage |
|------|----------|
| MCPAuth 401 / success / OPTIONS | Strong |
| MCPAuth 429 | **Missing** |
| CORS | **Missing** |
| Page / ErrorHTML / ErrorJSON | Smoke |

## Clean areas

No `Process.sleep`; SQL Sandbox correct; Auth + tenancy + cycle isolation well tested; RateLimit unit + MCPAuth 401 suite solid; no Mox misuse; 12/12 tools at least invoked once.
