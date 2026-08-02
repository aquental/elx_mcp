# Test Health Audit: ElxMCP

**Date:** 2026-08-02  
**Scope:** `test/**` (auth, mcp, plugs, projects, collaboration)  
**Suite run:** not executed (no shell in this reviewer); duration/cover inferred from structure only.

## Score: 76 / 100

| Dimension | Max | Score | Notes |
|-----------|-----|-------|-------|
| Coverage of public surface | 30 | 18 | Strong auth/projects/plugs; gaps on components, tenancy helpers, tool not_found matrix, collab write auth |
| No flaky patterns | 20 | 19 | No `Process.sleep`; ETS correctly `async: false` + reset |
| Async where possible | 15 | 11 | One missing `async: true`; one unjustified `async: false` |
| Mox at boundaries | 15 | 15 | N/A (no external I/O mocks) → full |
| Suite duration | 10 | 7 | ~70 tests, small; unmeasured; mono-test matrix hurts isolation not wall time |
| Error-path coverage | 10 | 6 | Auth/plugs strong; MCP tools + collab writes thin |

---

## Clean areas (one line each)

- **No `Process.sleep`** anywhere under `test/`.
- **ETS isolation correct:** `rate_limit_test`, `session_bind_test`, plug session/rate-limit use `async: false` + `reset!`.
- **Auth context** (`auth_test.exs`): verify/revoke/email/scopes/error paths solid.
- **Plug auth happy + 401** (`mcp_auth_test.exs`): assigns, header scrub, OPTIONS skip.
- **Session hijack reject** (`mcp_auth_session_test.exs`): POST/GET/DELETE foreign principal + owner unbind.
- **Projects tenancy isolation + cycle + association** covered in `projects_test.exs`.
- **Resources not_found + unauthorized** covered in `resources_test.exs`.
- **Sandbox** via `DataCase`/`ConnCase` for DB tests.
- **Mox:** not needed for current pure/DB surface.

---

## Iron Law / structure issues

### Warnings

- [ ] **`page_controller_test.exs:2`** — `use ElxMcpWeb.ConnCase` missing `async: true` (no global state). Fix: `use ElxMcpWeb.ConnCase, async: true`.
- [ ] **`validation_matrix_test.exs:6`** — `async: false` with no ETS/Application mutation; only Repo sandbox. Prefer `async: true` or justify shared state.
- [ ] **`validation_matrix_test.exs:13`** — single mega-test V01–V17 reduces failure locality; split per criterion.
- [ ] **`tools_test.exs:121`** — “list remaining tools” kitchen-sink test; one failure obscures which tool broke. Split per tool.

---

## Issues found

### Critical (coverage / error paths)

- [ ] **`Projects.create_component/2` untested** (`lib/elx_mcp/projects.ex:97`). Schema + `components`/`component_links` tables asserted in V01 only — no create/list/link behaviour.
- [ ] **MCP tool `not_found` almost untested.** Only `ListTickets` bad `story_key` (`tools_test.exs:97`). Missing error paths for `GetEpic`, `GetTicket`, `GetUserStory`, `ListComments`, `ListChangelog`, `SearchWorkItems` empty/invalid, `ListUserStories` filter misses.
- [ ] **Collaboration write-auth incomplete.** `create_comment` has `:forbidden` + foreign id; **no** `:forbidden`/foreign-entity tests for `create_attachment`, `create_worklog`, `record_changelog` (all use same `authorize_write` + `ensure_entity_in_project`).
- [ ] **`create_worklog` Multi failure path untested** — foreign/missing `ticket_id`, and `increment_time_spent` failure → `{:error, reason}` (`collaboration.ex:67-93`).
- [ ] **SessionBind invalid args / TTL untested.** No coverage for `{:error, :invalid_session}` (`session_bind.ex:69,90`) or expired-entry `lookup_live` path (`@ttl_ms`).
- [ ] **Session plug: owner GET success untested.** Only foreign GET 403; no “owner GET with bound session passes”.
- [ ] **RateLimit window rollover untested.** Counters per bucket; no short `window_ms` test that limit resets after window.

### Warnings (assertion strength / duplication)

- [ ] **`tools_test.exs:95`** — `assert text =~ "user_story" or text =~ ticket.title` is weak OR; prefer decoded JSON keys (`user_story` field present).
- [ ] **`tools_test.exs:68-72, 111-119, 121-143`** — many tools only assert `isError == false` without JSON shape/keys (unlike `list_epics`).
- [ ] **`resources_test.exs:107-114`** — `resource_text/1` falls back to `inspect(other)`; structural regressions can still “pass” if inspect accidentally contains substring.
- [ ] **`validation_matrix_test.exs:45`** — `assert {:error, _}` swallows changeset vs atom; prefer `errors_on` or `{:error, %Ecto.Changeset{}}`.
- [ ] **`validation_matrix_test.exs:67-93`** — V08–V14 are `function_exported?` / env smoke checks, not behavioural acceptance.
- [ ] **`projects_test.exs:98-99`** — `length(...) >= 1` after create is weak; assert created id/name membership.
- [ ] **`projects_test.exs:162-168`** — “default limit” only creates 3 epics and asserts `<= 50` (tautology); need 51+ or explicit `limit:` opt test.
- [ ] **Tenancy public API gaps:** no tests for `list_projects/0`, `get_project_by_key/1` (`tenancy.ex:10-17`).
- [ ] **`get_epic_id` / `get_user_story_id`** used by MCP tools, untested at context layer (only `get_ticket_id`).
- [ ] **Catalog** (`lib/elx_mcp/catalog.ex`) — zero direct tests for allowlists / `valid_status?` / `valid_priority?`.
- [ ] **No `mix test --cover` artifact** — cannot verify line coverage of `lib/elx_mcp/**` against claims above; run and attach report on next audit.

### Suggestions

- [ ] Split MCP tools into per-tool modules or `describe` blocks with happy + not_found + unauthorized.
- [ ] Property or table-driven tests for Catalog allowlists and Auth scope validation.
- [ ] Add explicit RateLimit test with `window_ms: 50` + `assert_receive`/busy-wait-free clock mock if extractable (or document single-node fixed-window as intentional).
- [ ] Consider `describe` blocks in `auth_test` / `projects_test` for scanability (not required for quality score).

---

## Per-area checklist

| Area | Async | Flaky risk | Happy | Error | Notes |
|------|-------|------------|-------|-------|-------|
| Auth | ok | low | strong | strong | |
| RateLimit | `false` ok | low | ok | partial | no window reset |
| SessionBind | `false` ok | low | ok | partial | no invalid/TTL |
| MCPAuth plug | ok | low | ok | strong 401 | |
| Session plug | `false` ok | low | partial | strong 403 | missing owner GET |
| Rate limit plug | `false` ok | low | n/a | 429 ok | unique IP |
| Projects | ok | low | good | good | no components |
| Collaboration | ok | low | ok | partial | write matrix incomplete |
| MCP tools | ok | low | broad | weak | kitchen-sink + few errors |
| MCP resources | ok | low | good | good | weak text helper |
| Tenancy | ok | low | minimal | key only | list/by_key missing |
| Validation matrix | unjustified `false` | low | smoke | weak | mega-test |

---

## Recommended next actions (priority)

1. Add MCP tool not_found/unauthorized matrix (highest product risk).
2. Cover `create_component` + collab write `:forbidden`/foreign entity for attachment/worklog/changelog.
3. Fix `page_controller_test` async; split validation matrix; strengthen weak length/OR asserts.
4. Run `mix test --cover` and store HTML/console output under `.claude/audit/reports/`.
