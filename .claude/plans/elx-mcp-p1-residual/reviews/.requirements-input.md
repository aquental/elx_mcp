# Plan: ElxMCP P1 Residual (post-audit 76/C)

**Status**: COMPLETED  
**Created**: 2026-08-02  
**Detail Level**: standard  
**Input**: `/phx:audit` → `.claude/audit/summaries/consolidated.md` + `project-health-2026-08-02.md` (overall **76/C**)  
**Prior plan**: `.claude/plans/elx-mcp-audit-fixes/plan.md` (COMPLETED — first remediation wave)

## Summary

Close the **seven P1 residual findings** from the 2026-08-02 re-audit so rate limiting actually works, MCP session lifecycle cannot be hijacked by another principal, read paths stop unbounded preloads / wasteful resolves, search is not full-table ILIKE, write surfaces stop latent IDOR, and MCP resources/429 are tested.

Target: re-audit trend toward **~80/B** (within ElxMCP only). No new product features.

## Scope

**In Scope (all audit P1s):**

1. Rate-limit ETS owned by Application (+ basic prune; 429 plug test)
2. MCP session ↔ `{api_key_id, project_id}` binding (or documented risk accept after spike)
3. Scope-first mutations + stop casting `:project_id` / enforce `project:write` at mutation boundary
4. Search: key exact/prefix fast path + `pg_trgm` (or FTS) for title; keep hard cap
5. Cap/paginate `get_*` association preloads
6. `list_comments` / `list_changelog` use `get_*_id` (+ add `get_ticket_id`)
7. MCP resource tests (4 missing) + stronger tool JSON asserts + Plug 429 integration

**Out of Scope (explicit defer — not P1):**

- Multi-node rate limit (Redis/Hammer) — document only
- Cursor pagination for all lists
- `Projects` multi-aggregate split
- Dead Component surface wire-up/removal
- API key `expires_at` (P2 security)
- `mix_audit` / sobelow install (P2 hygiene — optional Phase 6 if time)
- Full `/mcp` E2E beyond plug unit tests
- Dropping swoosh/req

## Finding → task map (completeness)

| Audit P1 | Plan tasks |
|----------|------------|
| Rate-limit ETS ownership | P1-T1, P1-T2, P5-T1 |
| MCP sessions not bound | P0-T1 → P1-T3 or P1-T3b |
| Dual Scope / bare `project_id` / unused `project:write` | P3-T1, P3-T2, P3-T3 |
| Leading-% ILIKE ×3 | P2-T3, P2-T4 |
| Unbounded `get_*` preloads | P2-T2 |
| comments/changelog full `get_*` | P2-T1 |
| Resources untested / tools smoke / 429 | P5-T1, P5-T2, P5-T3 |

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rate-limit ownership | Start ETS table from `Application` (or tiny owner process under supervisor); `setup!/0` no-ops if exists | Fix table death; keep atomic `update_counter` |
| Rate-limit prune | On check, opportunistic delete of buckets older than 2 windows; or periodic Task | Prevent unbounded ETS growth |
| Rate-limit key | Keep IP pre-auth for now; optional post-auth key out of scope | P1 is ownership, not multi-key redesign |
| Session bind | Spike first: if Anubis has no hook, use **app-owned ETS registry** `session_id → {api_key_id, project_id}` + plug guard on DELETE/GET before Anubis | Avoid forking Anubis |
| Session bind fallback | If plug cannot intercept DELETE safely, document risk + raise session entropy request upstream | Honest residual |
| Preload caps | Default child limit **50** on get_*; pass `limit` via opts; MCP get tools stay same API | Stops mega-JSON without breaking clients |
| ID resolve | Add `get_ticket_id/2`; switch comments/changelog to `get_*_id` | Pattern already exists for epic/story |
| Search | (1) exact `key` match first (2) prefix `key ILIKE 'q%'` (3) title via `pg_trgm` `%` or `similarity` (4) drop description from default search or optional flag | Avoid 3× full ILIKE seq scans |
| Write Scope API | `create_*(%Scope{}, attrs)` public; keep `create_*(project_id, attrs)` as deprecated private/admin used only by mix/tests | Latent IDOR before write tools |
| `project:write` | `Auth.authorize_write!(scope)` / `Scope.has_scope?` called from mutation contexts (not tools — none yet) | Catalog already has scope string |
| Cast | Remove `:project_id` from all schema cast lists; set via `put_change` from Scope | Ticket already correct |

## Module Structure (touches)

```
lib/elx_mcp/application.ex
lib/elx_mcp/auth/rate_limit.ex
lib/elx_mcp/auth/scope.ex                    # has_scope? already?
lib/elx_mcp/auth.ex                          # optional authorize helpers
lib/elx_mcp/auth/session_bind.ex             # NEW if spike chooses ETS bind
lib/elx_mcp_web/plugs/mcp_auth.ex            # or new plug after auth
lib/elx_mcp_web/plugs/mcp_session_guard.ex   # NEW optional
lib/elx_mcp/projects.ex
lib/elx_mcp/collaboration.ex
lib/elx_mcp/projects/{board,sprint,epic,user_story,component,ticket}.ex
lib/elx_mcp/collaboration/{comment,attachment,worklog,changelog}.ex
lib/elx_mcp/mcp/tools/{list_comments,list_changelog,get_*}.ex
priv/repo/migrations/*_search_trgm.exs
test/elx_mcp/auth/rate_limit_test.exs
test/elx_mcp_web/plugs/mcp_auth_test.exs
test/elx_mcp/mcp/{tools_test,resources_test}.exs
```

## Phase 0: Spike — MCP session binding [COMPLETED]

- [x] [P0-T1][security] Spike: can we bind sessions without forking Anubis? — Path A: plug-before-Anubis + SessionBind ETS — Path A: plug-before-Anubis + SessionBind ETS
  **Unknown**: Whether `StreamableHTTP.Plug` DELETE/GET can be wrapped so we reject session lifecycle when `conn.assigns.api_key_id` ≠ bound owner; whether session id is visible in conn before Anubis; whether initialize response is where we must register the bind.
  **Locations to read**:
  - `deps/anubis_mcp/lib/anubis/server/transport/streamable_http/plug.ex` (`handle_delete`, `get_or_create_session_id`, `find_or_create_session`)
  - Router: how `/mcp` is forwarded
  - Whether a plug *before* Anubis can see DELETE + session header and call a custom close only after ownership check
  **Success criteria** (pick one path, write result to `scratchpad.md`):
  - **Path A (preferred):** App ETS `session_id → {api_key_id, project_id}` registered on first authenticated POST after initialize; guard DELETE/GET SSE registration if mismatch → 403
  - **Path B:** Anubis config/hook exists for session metadata — use it
  - **Path C:** Not feasible without fork → document risk accept + residual for re-audit; skip P1-T3 implementation
  **Time-box**: 45 minutes

## Phase 1: Rate limit ownership + session bind [COMPLETED]

- [x] [P1-T1][otp] Own rate-limit ETS from Application — setup! in Application.start/2; opportunistic prune — setup! in Application.start/2; opportunistic prune
  **Locations**: `lib/elx_mcp/auth/rate_limit.ex`, `lib/elx_mcp/application.ex`
  **Implementation**:
  1. Add `RateLimit.child_spec/1` **or** call `RateLimit.setup!/0` from Application `start/2` before Endpoint (simplest: `RateLimit.setup!()` in `start/2` so the **Application process owns the table**).
  2. Change `setup!/0` so if table exists, return `:ok` without recreating.
  3. Remove create-on-every-`check/2` ownership risk: `check/2` assumes table exists; in test `setup` call `setup!` / `reset!`.
  4. Optional prune: when checking, if random 1/100 or every N checks, delete keys where `bucket < current - 2`.
  **Pattern**:
  ```elixir
  # application.ex start/2
  :ok = ElxMcp.Auth.RateLimit.setup!()
  children = [ ... ]
  ```
  Prefer Application-owned named ETS over GenServer unless prune needs a timer (then tiny GenServer under supervisor is OK).

- [x] [P1-T2][test] Prove counters survive process exit — rate_limit_test spawn/exit — rate_limit_test spawn/exit
  **Locations**: `test/elx_mcp/auth/rate_limit_test.exs`
  **Implementation**: Spawn a process that calls `check`, exit it, then check from test process — counters must still exist (limit still bites). Keep `async: false` for ETS suite.

- [x] [P1-T3][security] Implement session bind per spike Path A/B — SessionBind + MCPAuth enforce — SessionBind + MCPAuth enforce
  **Depends on**: P0-T1 Path A or B
  **Locations** (Path A):
  - NEW `lib/elx_mcp/auth/session_bind.ex` — ETS owned by Application
  - Plug after MCPAuth (or inside MCPAuth after success): on POST with session header, `SessionBind.bind_if_new(session_id, api_key_id, project_id)` / reject if bound to other key
  - On DELETE: verify ownership before forwarding to Anubis; if mismatch → 403
  **Note**: Tool data path already re-auths every POST — this only protects lifecycle disruption.
  **Skip if Path C** — replace with scratchpad residual note + README “known limitations” bullet.

- [x] [P1-T3b][direct] (Path C only) Document session residual — N/A Path A; README known limitations still documents residual multi-node/window — N/A Path A; README known limitations still documents residual multi-node/window
  **Locations**: `README.md` or `spec/SPEC.md` security section; `scratchpad.md`
  **Content**: Session DELETE/SSE keyed only by session id; tool tenant isolation still enforced; recommend private network + short-lived clients.

## Phase 2: Read-path performance P1s [COMPLETED]

- [x] [P2-T1][ecto] ID-only resolve for comments/changelog — get_ticket_id + tools use get_*_id — get_ticket_id + tools use get_*_id
  **Locations**:
  - `lib/elx_mcp/projects.ex` — add `get_ticket_id/2` (mirror `get_epic_id` / `get_user_story_id`)
  - `lib/elx_mcp/mcp/tools/list_comments.ex` — `resolve_entity/3` uses `get_*_id`
  - `lib/elx_mcp/mcp/tools/list_changelog.ex` — same
  **Pattern** (already partially present for list filters):
  ```elixir
  def get_ticket_id(%Scope{project_id: project_id}, key) when is_binary(key) do
    case Repo.one(from t in Ticket, where: t.project_id == ^project_id and t.key == ^key, select: t.id) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end
  ```
  ```elixir
  # list_comments resolve
  case Projects.get_ticket_id(scope, key) do
    {:ok, id} -> {:ok, id}
    err -> err
  end
  ```

- [x] [P2-T2][ecto] Cap `get_*` association preloads — child_limit default 50 — child_limit default 50
  **Locations**: `lib/elx_mcp/projects.ex` (`get_epic`, `get_user_story`, `get_ticket`)
  **Implementation**:
  - Default `:child_limit` 50 (opts, max 200).
  - Prefer query-based limited children instead of unbounded `Repo.preload`:
    - Epic: load epic, then `from us in UserStory, where: us.epic_id == ^id and us.project_id == ^pid, limit: ^n, order_by: [desc: us.updated_at]`
    - Story: limited tickets + belongs_to epic (single)
    - Ticket: belongs_to story + limited subtasks
  - Document in moduledoc that full child enumeration uses `list_*` with filters.
  - MCP get tools/resources unchanged at schema level; payload size drops for large trees.

- [x] [P2-T3][ecto] Search fast paths (no migration yet) — exact → prefix → title; desc opt-in — exact → prefix → title; desc opt-in
  **Locations**: `lib/elx_mcp/projects.ex` `search_work_items/3`
  **Implementation**:
  1. Normalize `q` (trim); if empty → `[]`.
  2. **Exact key** (case-insensitive): query each table `where key == ^up_or_as_is` (keys are project-scoped uppercase typically) — prefer exact hits first.
  3. **Prefix key**: if no/few exact hits, `ilike(key, ^prefix)` with `prefix = escape_like(q) <> "%"` (no leading `%`).
  4. **Title substring**: keep capped ILIKE on title only for remaining slots (still leading `%` until trgm).
  5. **Do not search description by default** (or only when `opts[:include_description] == true`).
  6. Keep hard cap `min(limit, 50)`.
  **Tests**: exact key hit returns item; leading-wildcard still works for title; description not matched unless flag.

- [x] [P2-T4][ecto] Migration: `pg_trgm` for title search — 20260802120000 + GIN indexes — 20260802120000 + GIN indexes
  **Locations**: `priv/repo/migrations/*_enable_pg_trgm_search.exs`, `projects.ex` search title clauses
  **Implementation**:
  ```sql
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  CREATE INDEX ... ON epics USING gin (title gin_trgm_ops);
  -- same for user_stories, tickets
  ```
  Use parameterized `ilike(title, ^pattern)` still (index can help with trgm) **or** `fragment("? % ?", title, ^q)` / similarity with threshold — pick simplest that uses GIN.
  **Note**: extension needs superuser on some hosts — document; if CI DB lacks rights, skip extension in test with try/rescue or `mix ecto` note. Prefer migration that is no-op-safe.

## Phase 3: Write-path Scope / cast hardening [COMPLETED]

- [x] [P3-T1][security] Scope-first public create APIs — create_*(%Scope{}, attrs) + authorize_write — create_*(%Scope{}, attrs) + authorize_write
  **Locations**: `lib/elx_mcp/projects.ex`, `lib/elx_mcp/collaboration.ex`, all call sites (mix tasks, tests)
  **Implementation**:
  ```elixir
  def create_epic(%Scope{} = scope, attrs) do
    :ok = authorize_write!(scope)
    create_epic(scope.project_id, attrs) # private
  end

  defp create_epic(project_id, attrs) when is_binary(project_id) do
    # existing body; put_change project_id
  end
  ```
  Apply to: board, sprint, component, epic, user_story, ticket, comment, attachment, worklog, changelog helpers used by tests.
  Update tests to pass `%Scope{}`. Mix `create_project` / seeds may use private or Tenancy path.

- [x] [P3-T2][ecto] Remove `:project_id` from schema casts — put_change in contexts; key too for issues — put_change in contexts; key too for issues
  **Locations**:
  - `projects/{board,sprint,epic,user_story,component}.ex`
  - `collaboration/{comment,attachment,worklog,changelog}.ex`
  **Implementation**: Drop `:project_id` (and issue `:key` where set by context) from `cast/3`; contexts already `put_change` / Map.put — switch Map.put to `put_change` for consistency (Ticket pattern).
  **Do not** cast association FKs that are tenant-sensitive without ownership check where still open (follow-up if time).

- [x] [P3-T3][security] Enforce `project:write` at mutation boundary — Auth.authorize_write/1 — Auth.authorize_write/1
  **Locations**: `lib/elx_mcp/auth/scope.ex` (ensure `has_scope?/2`), `auth.ex` or private `authorize_write!/1`
  **Implementation**:
  ```elixir
  defp authorize_write!(%Scope{scopes: scopes}) do
    if "project:write" in scopes, do: :ok, else: {:error, :forbidden}
  end
  ```
  Call from Scope-first creates. Leave `verify_api_key` requiring `project:read` for MCP reads (tools). Document that write keys need both scopes if they also call tools, **or** allow write-only keys for create-only once write tools exist — for now: mutations require `project:write`; tests create keys with both scopes when testing creates.
  **Test keys**: factory/setup helper `create_api_key(..., scopes: ["project:read", "project:write"])` for mutation tests.

## Phase 4: MCP test depth (P1 coverage) [COMPLETED]

- [x] [P5-T1][test] MCPAuth 429 integration — mcp_auth_rate_limit_test async:false — mcp_auth_rate_limit_test async:false
  **Depends on**: P1-T1
  **Locations**: `test/elx_mcp_web/plugs/mcp_auth_test.exs` (prefer `async: false` for this file or isolated module)
  **Implementation**: Configure low limit via `RateLimit.check` is internal — better: temporarily use Application config or pass limit through env for tests. Cleanest: extract limit from config:
  ```elixir
  # config/test.exs
  config :elx_mcp, :mcp_rate_limit, limit: 5, window_ms: 60_000
  ```
  Plug reads config. Test: with unique IP or `RateLimit.reset!`, fire `limit+1` authenticated or unauthenticated POSTs → last is 429 + `retry-after`.
  Use distinct rate-limit keys if concurrent tests share IP (`conn.remote_ip`).

- [x] [P5-T2][test] MCP resources (4 missing) — resources_test.exs — resources_test.exs
  **Locations**: NEW `test/elx_mcp/mcp/resources_test.exs` or extend `tools_test.exs`
  **Coverage**:
  | Resource | Happy | not_found | no scope |
  |----------|-------|-----------|----------|
  | Epic | ✓ | ✓ | ✓ (shared) |
  | UserStory | ✓ | ✓ | |
  | Ticket | ✓ | ✓ | |
  | Sprint | ✓ | ✓ | |
  | ProjectStatus | already smoke | | |
  Assert `type == :resource` and body includes known key/title JSON fields (decode if text).

- [x] [P5-T3][test] Stronger MCP tool assertions (shape, not only isError) — JSON decode + key asserts — JSON decode + key asserts
  **Locations**: `test/elx_mcp/mcp/tools_test.exs`
  **Implementation** (group, not one test per tool):
  - `list_epics` → decode JSON, assert `epics` is list, first has `"key"` / `"title"` when data seeded
  - `get_ticket` → assert body includes ticket key (not only title)
  - `list_tickets` **happy path** with story filter
  - `search_work_items` → exact key returns match
  - Keep unauthorized smoke for project_status

## Phase 5: Verification [COMPLETED]

- [x] [P6-T1][test] Full suite + format + compile — 64 tests pass; compile --warnings-as-errors — 64 tests pass; compile --warnings-as-errors
  ```
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix test
  ```
  Optional if installed: `mix credo --strict` (may not be in deps — skip if absent).

- [x] [P6-T2][direct] Update audit residual notes — scratchpad checklist + README limitations — scratchpad checklist + README limitations
  **Locations**: optional note in plan scratchpad “done checklist”; do **not** re-run full audit unless user asks `/phx:audit`.

## Task Agent Annotations

| Annotation | Agent | Use For |
|------------|-------|---------|
| `[ecto]` | ecto-schema-designer | Schemas, migrations, queries |
| `[otp]` | otp-advisor | Application/ETS ownership |
| `[security]` | security-analyzer | Auth, session bind, scopes |
| `[test]` | testing-reviewer | Tests |
| `[direct]` | (none) | Config, docs |

**Rules:** Security wins for auth/session. OTP for ETS ownership. Ecto for search/preloads/casts.

## Files to Follow as Patterns

- `lib/elx_mcp/projects.ex` — `get_epic_id/2`, `get_user_story_id/2`, `maybe_limit/2`, Ticket `put_change` for project_id
- `lib/elx_mcp/projects/ticket.ex` — cast without `:project_id`
- `test/elx_mcp/auth/rate_limit_test.exs` — ETS unit pattern (`async: false`)
- `test/elx_mcp_web/plugs/mcp_auth_test.exs` — plug unit style
- `test/elx_mcp/mcp/tools_test.exs` — frame/scope setup for tools/resources
- Prior remediation: `.claude/plans/elx-mcp-audit-fixes/plan.md` (completed)

## Patterns to Follow

- Scope on **reads**: first arg `%Scope{}`, pin `project_id == ^project_id`
- Never `String.to_atom` on input; never interpolate SQL
- Rate limit: atomic `:ets.update_counter/4`
- MCP tools: `Helpers.with_scope/2` + `emit_tool` + JSON reply
- Tests: DataCase sandbox; no `Process.sleep`

## Session Handoff

- **Discovery**: Rate-limit table is created by first `check/2` caller (request process) → dies with connection; this is the highest-impact prod bug among residuals. Tool tenant isolation is sound; session bind is lifecycle-only.
- **Decisions**: Prefer Application-owned ETS for rate limit; session bind via app registry if Anubis has no hook; search gets exact/prefix before trgm; write Scope API before any write MCP tools.
- **Warnings**:
  - `pg_trgm` may need superuser on managed Postgres — have ILIKE title fallback if extension fails
  - Changing `create_*` signatures breaks all tests — update in same phase
  - `MCPAuthTest async: true` + shared ETS can flake 429 tests — use `async: false` for 429 module
  - Do not fork Anubis; Path C is acceptable
  - Uncommitted local MCP tool edits may exist — rebase/commit hygiene before work

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Anubis session bind not pluggable | Path C document; still ship rate-limit + read fixes |
| `pg_trgm` blocked on DB | Ship P2-T3 without extension; T4 optional behind migration note |
| Scope API churn breaks mix tasks | Keep private `project_id` arity for admin/mix only |
| 429 tests flake with async | Dedicated `async: false` test module + unique keys + reset! |
| Preload rewrite changes JSON shape (missing children beyond 50) | Document + assert cap in tests; clients use list tools for full enumeration |

## Verification Checklist

- [x] `mix compile --warnings-as-errors` passes
- [x] `mix format --check-formatted` passes
- [x] `mix test` passes (expect ≥ 45; net + resources + 429 + search cases)
- [x] Rate limit: counter survives spawning process exit (automated)
- [ ] Manual (optional): two HTTP clients share limit after ETS fix
- [x] Every P1 finding has a completed task or Path C defer note

## Suggested `/phx:work` order

1. P0-T1 (spike) → choose Path A/B/C  
2. P1-T1 → P1-T2 → P1-T3/T3b  
3. P2-T1 → P2-T2 → P2-T3 → P2-T4  
4. P3-T1 → P3-T2 → P3-T3  
5. P5-T1 → P5-T2 → P5-T3  
6. P6-T1  

Parallelizable after P1-T1: Phase 2 (reads) ∥ Phase 3 (writes) once tests don’t share half-refactored creates.
