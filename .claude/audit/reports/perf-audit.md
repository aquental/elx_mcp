# Performance Audit — ElxMCP

**Date:** 2026-08-02  
**Scope:** `lib/elx_mcp/{projects,collaboration,auth,tenancy,repo}.ex`, `lib/elx_mcp/mcp/`, `lib/elx_mcp/auth/{rate_limit,session_bind}.ex`, `priv/repo/migrations/`  
**Score:** 77 / 100

## Score breakdown

| Category | Max | Score | Notes |
|----------|-----|-------|--------|
| N+1 / multi-query | 30 | 24 | No classic list N+1; search ≤9 RTTs; status_summary 7 RTTs; cycle walk O(depth) |
| Indexes | 20 | 14 | Title trgm + list composites present; collab/sprint/type shapes weak |
| Preloads | 15 | 14 | `child_limit` default 50 / max 200; sequential parent+children on get_* |
| GenServer / ETS / checkout | 15 | 10 | Double `with_tenant` per MCP call; SessionBind foldl prune; nested savepoints |
| LiveView streams | 10 | 10 | No collection LiveViews → full points |
| SELECT * / payload | 10 | 5 | Search/status slim; list/get encode full schemas + children |
| **Total** | **100** | **77** | |

---

## Issues found

### P1 — Double `with_tenant` + extra GUC round-trips on every MCP tool

**Where:** `lib/elx_mcp/mcp/helpers.ex:45-49`, `lib/elx_mcp/projects.ex:22-24`, `lib/elx_mcp/collaboration.ex:17`, `lib/elx_mcp/repo.ex:22-45`

**What:** `Helpers.with_scope/2` always opens `Repo.with_tenant/2` (depth 0 → full transaction + `set_config` ×2 on exit). Domain APIs (`Projects.*`, `Collaboration.*`) call `tenant/2` again, which hits the nested branch and **re-runs `set_tenant_guc!`** (another SQL round-trip) even when `project_id` is unchanged.

**Impact:** Every MCP tool pays:

1. `BEGIN` + dual `set_config` (set)
2. N × redundant `set_config` (one per nested `tenant/2`)
3. dual `set_config` (clear) + `COMMIT`

Hot paths with two domain calls (e.g. `list_tickets` + `get_user_story_id`, `list_comments` resolve + list) stack extra GUCs. Nested `Repo.transaction` / `Ecto.Multi` under `with_tenant` also create savepoints (`tenancy.ex:74-91` `next_issue_key`, `collaboration.ex:80-98` worklog Multi).

**Fix:**

- MCP tools: keep a single outer `with_tenant` and provide `*_unsafe` / internal variants that assume GUC is set; **or**
- Domain: skip re-entry when `Process.get({ElxMcp.Repo, :tenant_depth}, 0) > 0` and tenant matches (no second `set_config`);
- `next_issue_key`: drop the inner `Repo.transaction` when already inside `with_tenant` (use lock + update only).

---

### P1 — `search_work_items` multi-query fan-out (up to 9 sequential `Repo.all`)

**Where:** `lib/elx_mcp/projects.ex:408-568` (`search_exact_key`, `search_prefix_key`, `search_title` ×3 tables each)

**What:**

- Worst case: 3 stages × 3 tables = **9 round-trips** even after earlier stages nearly fill `limit`.
- Per-table `limit: ^limit` then `Enum.take(limit)` → up to **3× over-fetch** per stage before merge.
- Type-order merge (`epics ++ stories ++ tickets`) starves tickets when earlier types fill the cap.

**Fix:** `UNION ALL` + single `LIMIT`; allocate remaining budget across types; short-circuit remaining tables when `remaining == 0`.

---

### P1 — Leading-`%` title ILIKE residual + unindexed description / key ILIKE quirks

**Where:** `projects.ex:531-563`, `priv/repo/migrations/20260802120000_enable_pg_trgm_search.exs`

**What:**

- Title path `%"…"%` relies on `pg_trgm` GIN (`*_title_trgm_idx`). Extension needs superuser; if `CREATE EXTENSION` fails, title ILIKE degrades to seqscan with no app-level detection.
- `include_description: true` adds `ilike(description, …)` with **no** trgm/GIN on description → TOAST/seqscan risk. MCP tool does not expose the flag (default false), but domain allows it.
- Prefix key uses `ilike(e.key, ^prefix)` (`:501-524`); unique btree on `key` is case-sensitive and often **not** used by `ILIKE` (prefer `like` on uppercased prefix, or `citext` / functional index).

---

### P2 — `status_summary/2` — 7 sequential RTTs + 3× recent over-fetch

**Where:** `projects.ex:456-468`, helpers `:582-631`  
**Callers:** `mcp/tools/project_status.ex`, `mcp/resources/project_status.ex`

**What:** 3× `count_by_status` + 3× `recent_rows(limit)` + 1× `recent_tickets("in_review")`. `recent_items` loads `limit` from each type then sorts/takes in Elixir (up to 3× rows transferred).

**Fix:** one SQL with `FILTER` counts + `UNION ALL` recent; or overlap RTTs with `Task.async_stream` (same pool budget).

---

### P2 — List / get payloads are full schemas (SELECT *)

**Where:** `list_epics` / `list_user_stories` / `list_tickets` / boards / sprints (`projects.ex:44-355`); MCP `Helpers.encode_struct/1` (`mcp/helpers.ex:110-116`)

**What:** List endpoints load full rows (`description`, estimates, `metadata`, …). `get_*` loads full parent + up to `child_limit` (max 200) full child rows. Search/status paths correctly use slim `select` maps — list/get do not.

**Fix:** list projection (`key, title, status, priority, updated_at, …`); optional slim get modes.

---

### P2 — No offset/cursor pagination on list APIs

**Where:** Domain + MCP list tools — `limit` only (default 50–100, hard max 200)

**What:** Clients cannot page past the first window. `list_comments` MCP schema has **no** `limit` param (`mcp/tools/list_comments.ex:13-16`) — always domain default 100 (`collaboration.ex:41`).

---

### P2 — Collaboration / sprint / type index shapes incomplete

**Where:** `priv/repo/migrations/20260801200000_create_project_domain.exs`, list queries in `collaboration.ex` / `projects.ex`

| Query pattern | Present indexes | Gap |
|---------------|-----------------|-----|
| `list_comments`: `project_id + commentable_type + commentable_id` `ORDER BY inserted_at` | `comments(project_id)`, `(commentable_type, commentable_id)` | Composite `(project_id, commentable_type, commentable_id, inserted_at)` |
| `list_changelog`: same shape + `ORDER BY inserted_at DESC` | `changelogs(project_id)`, `(entity_type, entity_id)` | `(project_id, entity_type, entity_id, inserted_at)` |
| `list_sprints` + status | `sprints(project_id)`, bare `sprints(status)` | `(project_id, status)` |
| `list_tickets` + type | `tickets(type)` alone, `(project_id, status)` | `(project_id, type)` |
| stories by epic / tickets by story | `user_stories(epic_id)`, `tickets(user_story_id)` | Prefer `(project_id, epic_id)` / `(project_id, user_story_id)` under tenant filters |

List work-item indexes already good: `(project_id, status)`, `(project_id, updated_at)`, `(project_id, assignee_email)`, title trgm, unique keys.

---

### P2 — SessionBind prune cost / immortal legacy entries

**Where:** `lib/elx_mcp/auth/session_bind.ex:106-144`

**What:**

- 1% of `bind_if_new` runs **full-table `:ets.foldl`** + per-key delete → O(n) on the request path.
- Legacy 2-tuple entries `{sid, {api_key_id, project_id}}` (`:119-121`) **never expire** and are skipped by prune (no `bound_at`) → possible ETS growth if any remain.

RateLimit (`rate_limit.ex:91-101`) is healthier: Application-owned table + `select_delete` on old buckets. Single-node only (documented; multi-node needs Redis/Hammer).

**Fix:** `select_delete` matchspec on `bound_at`; drop/migrate legacy 2-tuples on read.

---

### P2 — Auth `touch_last_used` on hot path (sync write)

**Where:** `lib/elx_mcp/auth.ex:148-175` via `verify_api_key/2`

**What:** After successful verify, debounced (60s) sync `elx_mcp_touch_api_key` SQL on the request path. Race: two concurrent requests both pass debounce and both write. Extra RTT after key lookup + project load (`load_project/1`).

**Fix:** SQL gate `WHERE last_used_at IS NULL OR last_used_at < $cutoff`; or fire-and-forget / batch.

---

### P3 — Parent-cycle walk O(depth) queries

**Where:** `projects.ex:655-671` — one `Repo.get_by(Ticket, …)` per ancestor on create/parent update.

**Fix:** recursive CTE or single chain select of `id, parent_ticket_id` for the project.

---

### P3 — Existence checks load full rows

**Where:** `ensure_same_project/3` `projects.ex:636-640`; `exists_in_project?/3` `collaboration.ex:157-161`

**Fix:** `Repo.exists?/1` or `select: true` / `select: 1`.

---

### P3 — `escape_like/1` without SQL `ESCAPE`

**Where:** `projects.ex:705-710` escapes `\ % _` but Ecto `ilike/2` does not pass `ESCAPE '\'`; residual correctness under wildcards (minor noise / false matches).

---

### P3 — Concurrent issue-key generation serializes on project row

**Where:** `tenancy.ex:73-91` — `FOR UPDATE` on project + increment `issue_counter`.

**What:** Correct for uniqueness; under bursty creates within one tenant, writers queue on the project row. Acceptable for MVP; watch if create rate grows.

---

## Issue inventory

| # | Sev | Location | Summary |
|---|-----|----------|---------|
| 1 | P1 | `mcp/helpers.ex` + domain `tenant/2` + `repo.ex` | Double `with_tenant` / redundant GUC + savepoints |
| 2 | P1 | `projects.ex:408-568` | Search ≤9 queries; 3× over-fetch; type merge bias |
| 3 | P1 | search + trgm mig | Description ILIKE unindexed; key ILIKE residual; trgm optional |
| 4 | P2 | `projects.ex:456-631` | status_summary 7 RTTs + recent over-fetch |
| 5 | P2 | list/get + MCP encode | Full-schema SELECT * / encode |
| 6 | P2 | list_* APIs | No offset/cursor; list_comments no MCP limit |
| 7 | P2 | migrations / collab | Missing tenant+polymorphic composites; weak type/status |
| 8 | P2 | `session_bind.ex` | foldl prune O(n); legacy 2-tuples never expire |
| 9 | P2 | `auth.ex:148-175` | Sync touch_last_used on request path |
| 10 | P3 | `projects.ex:655-671` | Cycle walk N queries |
| 11 | P3 | projects/collaboration | Full-row existence checks |
| 12 | P3 | `projects.ex:705-710` | LIKE escape without ESCAPE clause |
| 13 | P3 | `tenancy.ex:73-91` | Issue key FOR UPDATE serialization |

---

SCORE: 77
