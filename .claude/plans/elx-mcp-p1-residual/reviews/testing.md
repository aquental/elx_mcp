# Test Review: ElxMCP P1 residual (changed tests)

## Summary

P5-T1/T2 land solid 429 + resource happy/not_found coverage; P1-T2 process-exit survival is good. **Security lifecycle coverage is incomplete**: only POST session bind 403 is tested — **DELETE/GET 403 and unbind are untested** despite production code in `MCPAuth.enforce_session_bind/2`. Shared ETS modules mix `async: true` (plug suite) with `async: false` + `reset!` (unit suites), which can flake under parallel ExUnit.

No `Process.sleep` found. Assertion strength is mixed: some JSON shape checks landed; several tools/resources still smoke-only.

## Iron Law Violations

- **ASYNC BY DEFAULT / shared ETS** — `MCPAuthTest` is `async: true` while mutating global `SessionBind` ETS; `SessionBindTest` / `RateLimitTest` use `async: false` + full-table `reset!`. Non-async and async cases can overlap in ExUnit → races.
- **NO PROCESS.SLEEP** — OK (none found).

## Issues Found

### BLOCKER

- [ ] **Missing session DELETE 403 plug test** (`mcp_auth_test.exs`)  
  Plan P1-T3: guard DELETE with ownership → 403. Impl: `mcp_auth.ex:68-76`. Tests only cover foreign principal on **POST** (L81–102).  
  **Fix:** Authenticated DELETE + `mcp-session-id` bound to another `api_key_id` → `status == 403`, body `session_forbidden`, `halted`.

- [ ] **Missing session GET 403 plug test** (same file)  
  Impl verifies on GET (`mcp_auth.ex:78-81`); no test.  
  **Fix:** Mirror DELETE/POST foreign-principal case for GET.

- [ ] **`MCPAuthTest` + SessionBind ETS not isolation-safe** (`mcp_auth_test.exs:2`, L87–90)  
  `async: true` + `SessionBind.bind_if_new` without suite-local cleanup; `SessionBindTest` does `reset!` (`session_bind_test.exs:8`).  
  **Fix:** `async: false` for any plug test that touches SessionBind/RateLimit tables, or isolate keys + never `delete_all_objects` while async peers run; prefer dedicated `MCPAuthSessionBindTest` with `async: false`.

### WARNING

- [ ] **DELETE success path / `unbind` untested**  
  Owner DELETE should verify + `SessionBind.unbind/1` (`mcp_auth.ex:70-72`). Unit suite never calls `unbind`.  
  **Fix:** Owner DELETE → not 403; subsequent foreign bind_if_new on same sid allowed (or verify unbound).

- [ ] **Session bind happy path missing at plug**  
  No test that matching principal POST with session header succeeds and re-POST is allowed. Only reject path covered.

- [ ] **P5-T3 only partial** (`tools_test.exs`)  
  Strong JSON: `list_epics`, `list_tickets` happy. Weak: `project_status` (L68–72 type only); `list remaining tools` (L121–143) only `isError == false`; `get_ticket` uses `=~ "user_story" or =~ title` (L95).  
  **Fix:** Jason.decode + required keys for list/get tools still smoke-only.

- [ ] **`resource_text/1` masks failures** (`resources_test.exs:107-114`)  
  Fallback `inspect(other)` makes `=~ "not_found"` pass on wrong shapes.  
  **Fix:** Pattern-match expected content shape; `flunk` on mismatch. Prefer Jason fields over substring/`or` (L94).

- [ ] **RateLimit first test uses fixed key** (`rate_limit_test.exs:13-15`)  
  `"test:ip"` relies entirely on `reset!`; OK only while suite stays serial. Prefer unique keys everywhere (as other tests do).

- [ ] **No rate-limit prune / window-roll coverage**  
  P1-T1 opportunistic prune (`rate_limit.ex:88-95`) untested (optional but residual).

- [ ] **P2-T2 child_limit preload cap untested** (`projects_test.exs`)  
  Plan caps `get_*` associations at 50; no test that >50 children are truncated.

- [ ] **Collaboration write auth gaps** (`collaboration_test.exs`)  
  `create_comment` forbids read-only; `create_worklog` / `create_attachment` lack `:forbidden` cases. Attachment isolation lists comments, not attachments (L68–101).

- [ ] **Validation matrix weak / incomplete** (`validation_matrix_test.exs`)  
  Monolith + `async: false`; V04 uses `{:error, _}` not changeset; bilingual `or` soft; no V10/V11/V15/V17 markers; does not assert session bind or 429 (P1 residuals).

### SUGGESTION

- [ ] **SessionBind race branch** (`insert_new` false → re-verify) untested — hard to unit without concurrency helper; document or property/concurrent test.
- [ ] **429 only via unauthenticated 401s** (`mcp_auth_rate_limit_test.exs`) — path is shared; optional authenticated 429 for clarity.
- [ ] **Resources unauthorized** only for Epic — one shared test is enough if documented.
- [ ] Split validation matrix into per-V tests with stronger asserts; keep as checklist only if intentional.
- [ ] `start_supervised!` N/A for ETS tables (Application-owned) — OK.

## Coverage vs plan P5

| Task | Status in tests |
|------|-----------------|
| P5-T1 429 + retry-after | Present (`mcp_auth_rate_limit_test.exs`) |
| P5-T2 Epic/US/Ticket/Sprint happy+not_found | Present; assertion strength medium |
| P5-T3 stronger tool JSON | Partial (list_epics, list_tickets; rest smoke) |
| P1-T2 counter survives exit | Present |
| P1-T3 DELETE/GET session 403 | **Missing (BLOCKER)** |

## Verdict

**REQUIRES CHANGES** — add DELETE/GET session 403 plug tests and fix SessionBind ETS async isolation before treating P1 residual as test-complete.
