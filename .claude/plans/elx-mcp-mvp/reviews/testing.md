# Test Review: ElxMCP MVP

## Summary

Core happy paths for API keys, issue keys, story/ticket rules, one isolation case, and plug 401s are covered. **Large public-API surface is untested** (most `Projects`/`Collaboration` functions, 10/12 MCP tools, all resources, authenticated `/mcp` integration). Auth edge cases and collaboration tenancy isolation are thin. Iron laws (async, sandbox, no sleep/Mox) are mostly fine; `validation_matrix_test` uses `async: false` without need.

**Verdict: REQUIRES CHANGES** (Critical coverage gaps on new public APIs).

## Iron Law Violations

- None severe (no `Process.sleep`, no internal mocks, sandbox via `DataCase`/`ConnCase`).
- **Soft:** `test/elx_mcp/validation_matrix_test.exs:6` uses `async: false` with no global env/Mox — should be `async: true` unless concurrent `pg_tables`/schema checks require serial (they do not).

## Issues Found

### Critical

- [ ] **BLOCKER — Massive `Projects` public API untested** (`lib/elx_mcp/projects.ex`). Zero or near-zero coverage for: `create_board`/`list_boards`, `create_sprint`/`list_sprints`, `create_component`, `create_epic`/`list_epics`/`get_epic`, `get_user_story`, `list_tickets` (+ filters), `search_work_items`, parent **cycle detection** (`validate_parent_cycle` / `{:error, :cycle_detected}`). Only story create, ticket create rules, `get_ticket`, one list, and `status_summary` are exercised in `projects_test.exs`. Add focused `describe` blocks per entity + filter/search/cycle cases.

- [ ] **BLOCKER — MCP tools/resources almost untested** (`test/elx_mcp/mcp/tools_test.exs`). Only `ProjectStatus` + `ListEpics` + empty-frame unauthorized. Untested tool modules: `GetEpic`, `GetTicket`, `GetUserStory`, `ListBoards`, `ListSprints`, `ListTickets`, `ListUserStories`, `ListComments`, `ListChangelog`, `SearchWorkItems`. **Zero** resource tests (`mcp/resources/*`). Not-found paths and filter params never asserted.

- [ ] **BLOCKER — No authenticated end-to-end `/mcp` ConnCase integration**. `mcp_auth_test.exs` posts `/mcp` only for **401** paths; valid-key test calls `MCPAuth.call/2` in isolation and never hits `Anubis.Server.Transport.StreamableHTTP.Plug` with assigns. Need ConnCase (or transport-level) tests: valid `X-API-Key` → non-401 through pipeline; tool invoke with tenant assigns.

- [ ] **BLOCKER — Auth scope gate untested** (`auth.ex:44`). Key with scopes **not** containing `"project:read"` must return `{:error, :unauthorized}`. Also untested: `verify_api_key/1` non-binary (`nil`/atom), `get_api_key!/1`, `last_used_at` touch after verify.

- [ ] **BLOCKER — Collaboration isolation + attachment gap**. `create_attachment/2` has **no tests**. `list_comments` / `list_changelog` have no cross-tenant isolation (unlike projects). `create_worklog` with wrong `project_id` vs ticket’s project (or foreign ticket id) not asserted; multi-worklog time accumulation (3600+3600) not tested.

### Warnings

- [ ] **WARNING — Tenancy concurrency / API surface** (`tenancy_test.exs`). Only sequential `next_issue_key`; no concurrent `Task.async` uniqueness test for `FOR UPDATE`. `list_projects`, `get_project_by_key`, missing-project `next_issue_key` / `get_project!` raise paths untested. Duplicate project key uniqueness untested.

- [ ] **WARNING — Isolation incomplete** (`projects_test.exs:59-70`). Covers `list_user_stories` + `get_ticket` only. Missing: epic/ticket lists, `search_work_items`, `status_summary`, boards/sprints, and collaboration lists under foreign scope. Same-key across tenants (two projects both with `XXX-1`) not covered.

- [ ] **WARNING — Write path bypasses `Scope`**. Creates take raw `project_id`; tests never assert that MCP tools cannot write across tenants (read-only MVP?) but context creates are open — document and test intended authorization model for any future write tools.

- [ ] **WARNING — Plug edges** (`mcp_auth_test.exs`). OPTIONS bypass (`call` for `"OPTIONS"`) untested. Empty/`Bearer` malformed header shapes untested. Successful path does not assert `current_scope` / `scopes` / `api_key_id` / `key_prefix` assigns fully.

- [ ] **WARNING — `validation_matrix_test.exs` is a weak smoke mega-test**. Single test claims V01–V17 but skips/weakly covers V10–V11, V15, V17 (no comments in file); V08–V09 are `function_exported?`/`Code.ensure_loaded?` only; V12 bilingual assert is loose (`=~ "status"`). Prefer splitting V-cases into real assertions or drop false “V01-V17 complete” claim.

- [ ] **WARNING — Subtask happy path only in matrix**, not `projects_test` (reject path is covered; success path + parent cycle not).

### Suggestions

- [ ] **SUGGESTION — Structure**: add `describe` blocks per function/entity; named setup helpers (`:project_with_scope`, `:ticket_fixture`) instead of duplicated Scope maps.

- [ ] **SUGGESTION — Factories**: no ExMachina/factory; repeated create chains across 5 files — extract `test/support/factory.ex` with `build`/`insert` for Project, ApiKey, Story, Ticket.

- [ ] **SUGGESTION — Stronger tool assertions**: decode JSON tool content and assert keys/counts, not only `isError == false`.

- [ ] **SUGGESTION — `async: true` on validation matrix** unless proven serial need.

- [ ] **SUGGESTION — Property tests**: issue key format (`PROJECT-\d+`), hex API key roundtrip hash, `escape_like` for `search_work_items`.

## Coverage map (public vs tests)

| Module | Public functions | Tested (meaningfully) | Gap severity |
|--------|------------------|----------------------|--------------|
| `Auth` | create/verify/revoke/list/get | create, verify, revoke, list | get!, scope deny, non-binary |
| `Tenancy` | list/get/get_by_key/create/next_key | create, next_key, invalid key | list, get_by_key, concurrency |
| `Projects` | ~15 public | ~6 scenarios | boards/sprints/components/epics/search/cycle |
| `Collaboration` | 6 public | comment+changelog+1 worklog | attachment, isolation, multi worklog |
| MCP Tools | 12 | 2 + unauth | 10 tools + not_found |
| MCP Resources | 4 | 0 | all |
| `MCPAuth` plug | call/OPTIONS | 401s + isolated ok | OPTIONS, full /mcp auth |

## ExUnit patterns checklist

| Check | Status |
|-------|--------|
| `async: true` default | Pass (except validation matrix) |
| Sandbox isolation | Pass |
| `describe` grouping | Weak / missing |
| Pattern-match asserts | Pass |
| No `Process.sleep` | Pass |
| Mox / verify_on_exit | N/A |
| ConnCase for HTTP | Partial (401 only) |
| LiveView / Oban | N/A |
