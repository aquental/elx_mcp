# Test Health Audit: ElxMCP

**Date:** 2026-08-02  
**Scope:** `test/**`, `test/support/`, corresponding `lib` contexts  
**Commands:** static analysis only — no shell available; `mix test --failed` / `mix test --cover` **not executed**

## Inventory

| Metric | Value |
|--------|-------|
| Test modules (`*_test.exs`) | 16 |
| `test "..."` cases | **78** |
| `async: true` modules | 9 |
| `async: false` modules | 6 (ETS/global: RateLimit, SessionBind, plugs; RLS; validation matrix) |
| Missing async opt | 1 — `page_controller_test.exs` |
| `Process.sleep` | **0** |
| `verify_on_exit!` / Mox | **0** (no mocks; no external HTTP boundaries in suite) |
| `describe` blocks | **0** |
| Factories / ExMachina | none — inline `setup` + context creates |
| Support | `DataCase` + `ConnCase` only (Sandbox OK) |

**`rg` patterns (static):**

- `async: true` — 9 modules (+ docs in support)
- `async: false` — 6 modules
- `Process.sleep` — none
- `verify_on_exit` — none

---

## Score breakdown

| Dimension | Max | Score | Rationale |
|-----------|-----|-------|-----------|
| Coverage of public surface | 30 | 19 | Auth, Projects core, RLS, MCP plugs/resources solid; gaps below |
| No flaky patterns | 20 | 19 | No sleep; ETS correctly `async: false` + `reset!` |
| Async where possible | 15 | 12 | One missing `async: true`; one unjustified `async: false` |
| Mox at boundaries | 15 | 15 | N/A — pure/DB surface; no false internal mocks |
| Suite duration | 10 | 6 | Unmeasured; ~78 cases small but cover/runtime unknown |
| Error-path coverage | 10 | 6 | Auth/plugs/RLS strong; tools + collab writes incomplete |
| **Total** | **100** | **77** | |

---

## Iron law / structure issues

### Warnings

- [ ] **`test/elx_mcp_web/controllers/page_controller_test.exs:2`** — `use ElxMcpWeb.ConnCase` without `async: true`. No Application/ETS mutation. Fix: `use ElxMcpWeb.ConnCase, async: true`.
- [ ] **`test/elx_mcp/validation_matrix_test.exs:6`** — `async: false` with only Repo sandbox usage (no ETS/global). Prefer `async: true` or document shared-state reason.
- [ ] **No `describe` blocks** in any module — harder scanability for large files (`projects_test`, `tools_test`).
- [ ] **`validation_matrix_test.exs:13`** — single mega-test V01–V17; one failure loses locality. Split per criterion.
- [ ] **`tools_test.exs:121`** — kitchen-sink “list remaining tools”; one assert failure obscures which tool broke.

---

## Coverage gaps (Critical for product surface)

### Auth (`lib/elx_mcp/auth.ex` + plugs)

- [ ] **`Auth.get_api_key!/1` untested** — raise path + happy path.
- [ ] **`Auth.authorize_write/1` only exercised indirectly** — no direct unit cases for `:ok` / `:forbidden`.
- [ ] **`touch_last_used` debounce** (`@last_used_debounce_seconds`) untested.
- [ ] **SessionBind `{:error, :invalid_session}`** (`session_bind.ex:69,90`) — empty/nil session_id, nil keys untested.
- [ ] **SessionBind TTL / expired entry** (`@ttl_ms`, `lookup_live`) untested — expiry is security-relevant for hijack window.
- [ ] **Session plug: owner GET success untested** — only foreign GET 403 (`mcp_auth_session_test.exs:92`); missing “owner GET with bound session passes”.
- [ ] **RateLimit window rollover untested** — no short `window_ms` proving counter reset (unit + plug).
- [ ] **CORS plug (`ElxMcpWeb.Plugs.CORS`) untested** — only `is_list(mcp_cors_origins)` smoke in validation matrix; no allowlist / OPTIONS 204 / star-in-prod denial.

### Projects

- [ ] **`Projects.create_component/2` untested** (`projects.ex:111`) — tables asserted in V01 only; no create/link behaviour for `components` / `component_links`.
- [ ] **`get_epic_id` / `get_user_story_id` untested at context layer** (used by MCP list tools); only `get_ticket_id` covered.
- [ ] **`increment_time_spent/3` public API untested** directly (only via worklog happy path).
- [ ] **`projects_test.exs:162-168`** — “default limit” creates 3 epics and asserts `<= 50` (tautology). Need 51+ rows or explicit `limit:` opt.
- [ ] **`projects_test.exs:98-99`** — `length(...) >= 1` after create is weak; assert id/name membership.

### Collaboration

- [ ] **Write-auth matrix incomplete** — `create_comment` has `:forbidden` + foreign entity; **missing** same for `create_attachment`, `create_worklog`, `record_changelog` (all share `authorize_write` + `ensure_entity_in_project`).
- [ ] **`create_worklog` error paths untested** — missing/foreign `ticket_id` → Multi `{:error, reason}` (`collaboration.ex:90-102`).
- [ ] **No attachment list API** — create-only coverage; cross-tenant isolation asserts comments/changelog empty but not attachment visibility (no list function).

### MCP tools / resources

- [ ] **Tool `not_found` almost untested** — only `ListTickets` bad `story_key` (`tools_test.exs:97`). Missing for `GetEpic`, `GetTicket`, `GetUserStory`, `ListComments`, `ListChangelog`, invalid entity_type, empty search.
- [ ] **Unauthorized only on `ProjectStatus`** (`tools_test.exs:145-162`) — not asserted per-tool (shared helper risk if one tool skips check).
- [ ] **Weak tool assertions** — many only `isError == false` without JSON shape (`tools_test.exs:68-72, 111-143`); weak OR at line 95: `text =~ "user_story" or text =~ ticket.title`.
- [ ] **`resources_test.exs` helper** `resource_text/1` falls back to `inspect(other)` — structural regressions can pass on accidental substring match.

### Tenancy / Catalog / other

- [ ] **Tenancy context thin** — create + invalid key + issue keys; `list_projects` / `get_project_by_key` covered only inside `rls_test.exs` (not tenancy_test). Acceptable but easy to miss on context refactor.
- [ ] **`ElxMcp.Catalog` zero tests** — allowlists / `valid_status?` / `valid_priority?` drive changesets; no unit or property tests.
- [ ] **No LiveView / no Oban** in app — N/A (not gaps).

### RLS (`rls_test.exs`)

- Coverage is **relatively strong** (isolation, GUC leak, WITH CHECK, SECURITY DEFINER cold path). Residual gaps only:
- [ ] No RLS coverage for **comments/attachments/worklogs** tables (only boards + api_key path).
- [ ] No concurrent multi-connection RLS stress (optional; async:false already).

---

## Error path vs happy path

| Area | Happy | Error | Verdict |
|------|-------|-------|---------|
| Auth context | strong | strong (email, revoke, scopes, invalid) | OK |
| MCPAuth plug | OK | strong 401 matrix | OK |
| Session plug | partial | strong 403 | gap: owner GET |
| Rate limit | unit OK | 429 plug OK | gap: window reset |
| Projects | good | good (forbidden, cycle, assoc, validation) | gap: components |
| Collaboration | OK | partial | gap: write matrix |
| MCP tools | broad | weak | **highest gap** |
| MCP resources | good | good not_found/unauth | OK |
| RLS | good | good | OK |
| Validation matrix | smoke | weak `{:error, _}` | not real acceptance |

---

## Flaky / order-dependent patterns

- [ ] **None of `Process.sleep` / timing races** found.
- [ ] **ETS modules correctly non-async** with `reset!` in setup/on_exit — low flake risk.
- [ ] **Rate-limit plug** uses fixed `remote_ip` `{203,0,113,50}` + `reset!` — OK if suite always resets; concurrent external process could collide only if another test reuses that IP without reset (currently only this module).
- [ ] **Hardcoded project keys** (`AUTH`, `PRJ`, `COL`, …) — unique per module + sandbox isolation → OK under Postgres sandbox; would collide if tests shared DB without sandbox (they don’t).

---

## Runtime / cover (blocked)

- [ ] **`mix test --failed` not run** — no shell in this auditor; cannot confirm green suite or last failures.
- [ ] **`mix test --cover` not run** — no line-coverage artifact; coverage scores above are API-surface estimates only.
- **Action for human/CI:**  
  `mix test --failed 2>&1 | tail -20`  
  `mix test --cover 2>&1 | tail -40`  
  store under `.claude/audit/reports/`.

---

## Recommended next actions (priority)

1. MCP tools **not_found + unauthorized** matrix (product risk).
2. Collab write `:forbidden`/foreign for attachment/worklog/changelog; `create_component` tests.
3. Fix `page_controller` async; split validation matrix; CORS plug tests.
4. SessionBind invalid args + document or test TTL; RateLimit window reset.
5. Run `mix test --cover` and attach numbers to next audit.

---

SCORE: 77
