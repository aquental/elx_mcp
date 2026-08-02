# Performance Audit — ElxMCP

**Date:** 2026-08-02  
**Score:** 80 / 100  
**Grade:** B  
**Scope:** `lib/elx_mcp/projects.ex` (`search_work_items`, `get_*`/`list_*` + `child_limit`), `lib/elx_mcp/collaboration.ex`, `priv/repo/migrations` (indexes, `pg_trgm`), RateLimit / SessionBind ETS prune  
**Baseline:** Prior audit (72/C) is **stale** — code now has key exact/prefix paths, `pg_trgm` GIN on titles, capped `child_limit` preloads, `get_*_id`, Application-owned ETS + bucket prune.

---

## Score breakdown

| Category | Max | Score | Notes |
|----------|-----|-------|--------|
| N+1 / multi-query | 30 | 24 | No classic list N+1; search ≤9 RTTs; `status_summary` 7 RTTs; cycle walk O(depth) |
| Indexes | 20 | 15 | Title trgm + list composites present; description residual; weak collab/sprint/type shapes |
| Preloads | 15 | 14 | `child_limit` default 50 / max 200; not unbounded |
| GenServer / ETS | 15 | 12 | RateLimit prune OK; SessionBind foldl + immortal legacy tuples |
| LiveView streams | 10 | 10 | N/A (no collection LiveViews) → full points |
| SELECT * / payload | 10 | 5 | Search/status slim; list/get encode full schemas + children |
| **Total** | **100** | **80** | |

---

## Issues found

### P1

1. **`search_work_items` multi-query fan-out (up to 9 sequential `Repo.all`)**  
   - `lib/elx_mcp/projects.ex:361-511` (`search_exact_key` ×3, `search_prefix_key` ×3, `search_title` ×3)  
   - Worst case: three stages always hit three tables even when earlier stages nearly fill `limit`.  
   - Per-table `limit: ^limit` then `Enum.take(limit)` → up to **3× over-fetch** per stage before merge.  
   - Type-order merge (`epics ++ stories ++ tickets`) starves tickets when earlier types fill the cap.  
   - **Fix:** UNION ALL + single `LIMIT`; or stop querying remaining tables once `remaining == 0` *and* short-circuit exact-key hits; allocate remaining budget across types (or rank score).

2. **Leading-`%` title ILIKE residual + unindexed description path**  
   - Title: `%"…"%` uses `pg_trgm` GIN when extension/migration applied (`20260802120000_enable_pg_trgm_search.exs` — `*_title_trgm_idx`).  
   - **Residual:** `include_description: true` adds `ilike(description, ^pattern)` with **no** trgm/GIN on description → TOAST/seqscan risk (`projects.ex:474-506`). MCP tool currently does not expose the flag (default false) — domain still allows it.  
   - Prefix key path uses `ilike(key, ^prefix)` (`:444-471`); unique btree on `key` is case-sensitive and often **not** used by `ILIKE` (prefer `like` on uppercased prefix, or `citext`/functional index).  
   - Extension requires superuser; if `CREATE EXTENSION` fails, title ILIKE degrades to seqscan with no app-level detection.

### P2

3. **`status_summary/2` — 7 sequential round-trips + 3× recent over-fetch**  
   - `projects.ex:401-411`, helpers `:525-575`  
   - 3× `count_by_status` + 3× `recent_rows(limit)` + 1× `recent_tickets("in_review")`.  
   - `recent_items` loads `limit` from each type then sorts/takes in Elixir (up to 3× rows).  
   - Callers: `mcp/tools/project_status.ex`, `mcp/resources/project_status.ex`.  
   - **Fix:** one SQL with FILTER counts + `UNION ALL` recent; or `Task.async_stream` for RTT overlap.

4. **List / get payloads are full schemas (SELECT *)**  
   - `list_epics` / `list_user_stories` / `list_tickets` / boards / sprints → full structs; MCP `Helpers.encode_struct/1` ships `description`, estimates, metadata.  
   - `get_*` loads full parent row + up to `child_limit` full child rows (still heavy at max 200).  
   - **Fix:** list projection (`key,title,status,priority,updated_at,…`); optional slim get modes.

5. **No offset/cursor pagination on list APIs**  
   - Domain + MCP list tools: `limit` only (default 50–100, hard max 200). Clients cannot page past first window.  
   - `list_comments` MCP schema has **no** `limit` param (`mcp/tools/list_comments.ex:13-16`) — always domain default 100.

6. **Collaboration list index shapes incomplete**  
   - Queries filter `project_id + type + id` (+ `order_by inserted_at`):  
     - `list_comments` `collaboration.ex:36-47`  
     - `list_changelog` `collaboration.ex:115-126`  
   - Present: separate `project_id` and `(commentable_type, commentable_id)` / `(entity_type, entity_id)` (`create_project_domain.exs:188-189,244-245`).  
   - Missing covering composites:  
     - `(project_id, commentable_type, commentable_id, inserted_at)`  
     - `(project_id, entity_type, entity_id, inserted_at)`  
   - Also weak: bare `sprints:status`, bare `tickets:type` vs tenant filters `(project_id, status)` / `(project_id, type)`.

7. **SessionBind prune cost / immortal legacy entries**  
   - `lib/elx_mcp/auth/session_bind.ex:125-144` — 1% of `bind_if_new` runs **full-table `:ets.foldl`** + per-key delete (O(n)). Prefer `select_delete` with matchspec on `bound_at`.  
   - Legacy 2-tuple `{sid, {api_key_id, project_id}}` (`:119-121`) **never expire** and are skipped by prune (no timestamp) → ETS leak if any remain.  
   - RateLimit (`rate_limit.ex:91-101`) is healthier: Application-owned table + `select_delete` buckets older than 2 windows (1% of checks). Single-node only (documented).

8. **Auth `touch_last_used` on hot path**  
   - `lib/elx_mcp/auth.ex:126-137` — 60s debounce then sync `update_all` by id; read-then-write race; no SQL gate `WHERE last_used_at IS NULL OR last_used_at < ^cutoff`.

### P3

9. **Parent-cycle walk O(depth) queries**  
   - `projects.ex:588-614` — one `Repo.get_by(Ticket, …)` per ancestor on create/parent update. Prefer recursive CTE / single chain select.

10. **Existence checks load full rows**  
    - `ensure_same_project/3` `projects.ex:579-584`; `exists_in_project?/3` `collaboration.ex:142-146` — use `Repo.exists?` / `select: true`.

11. **`escape_like/1` without SQL `ESCAPE`**  
    - `projects.ex:648-653` escapes `\ % _` but Ecto `ilike/2` does not pass `ESCAPE '\'`; residual correctness under wildcards (minor perf noise).

---

## Clean areas (one line each)

- No `Repo` inside `Enum.map` over query results on read paths (no classic N+1).  
- `get_*` children capped via `child_limit` default 50 / max 200 (`projects.ex:19-20,515-518`).  
- `get_epic_id` / `get_user_story_id` / `get_ticket_id` used by list filters + comments/changelog resolve.  
- `list_*` work items default limit 50, hard max 200 (`maybe_limit/2`).  
- Search hard-caps `min(limit, 50)`; key exact path + optional description opt-in.  
- Title `pg_trgm` GIN indexes migrated (`epics` / `user_stories` / `tickets`).  
- List indexes: `(project_id, status)`, `(project_id, updated_at)`, `(project_id, assignee_email)`.  
- Search / status recent paths use slim `select` maps (not full structs).  
- RateLimit: Application-owned ETS, atomic `update_counter`, opportunistic `select_delete` prune.  
- SessionBind: Application-owned ETS, TTL on 3-tuples, refresh-on-activity.  
- `increment_time_spent` single `update_all`; worklog uses `Ecto.Multi`.  
- No collection LiveViews (MCP-first) — streams N/A.

---

## Issue inventory

| # | Sev | Location | Summary |
|---|-----|----------|---------|
| 1 | P1 | `projects.ex:361-511` | Search ≤9 queries; 3× over-fetch; type merge bias |
| 2 | P1 | `projects.ex:474-506`, trgm mig | Description ILIKE unindexed; key ILIKE residual; trgm optional |
| 3 | P2 | `projects.ex:401-575` | status_summary 7 RTTs + recent over-fetch |
| 4 | P2 | list/get + MCP encode | Full-schema SELECT * / encode |
| 5 | P2 | list_* APIs | No offset/cursor; list_comments no MCP limit |
| 6 | P2 | migrations / collab | Missing tenant+polymorphic composites; weak type/status |
| 7 | P2 | `session_bind.ex` | foldl prune O(n); legacy 2-tuples never expire |
| 8 | P2 | `auth.ex:126-137` | Sync touch_last_used on request path |
| 9 | P3 | `projects.ex:588-614` | Cycle walk N queries |
| 10 | P3 | projects/collaboration | Full-row existence checks |
| 11 | P3 | `projects.ex:648-653` | LIKE escape without ESCAPE clause |

---

## Suggested fix priority (not implemented)

1. Collapse search stages into fewer queries / budget-aware early exit; keep hard cap.  
2. Confirm `pg_trgm` live in prod; add description trgm only if `include_description` is productized; prefer `like` on uppercased keys for prefix.  
3. Composite collab indexes; `(project_id, type)` / sprint tenant+status.  
4. Slim list selects; cursor pagination; expose `limit` on `list_comments`.  
5. Parallelize or CTE-collapse `status_summary`.  
6. SessionBind: `select_delete` prune; drop/migrate legacy 2-tuples.  
7. SQL-gated or async `last_used_at`; `exists?` for association checks.

---

*End of performance audit. Issues only; no application code changed.*
