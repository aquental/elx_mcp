# Performance Audit — ElxMCP

**Date:** 2026-08-01  
**Scope:** `lib/elx_mcp/projects.ex`, `collaboration.ex`, `auth.ex`, migrations, MCP list/search tools  
**Performance score:** **58 / 100**

Report lists **issues only**. Severity: P1 (high impact under growth/load), P2 (moderate), P3 (lower / edge).

---

## P1 — `status_summary/2` query fan-out + over-fetch

**Where:** `lib/elx_mcp/projects.ex` (`status_summary`, `recent_items`, `count_by_status`)  
**Callers:** `MCP.Tools.ProjectStatus`, `MCP.Resources.ProjectStatus`

Each call issues **7 DB round-trips**:

1. `count_by_status(Epic)`  
2. `count_by_status(UserStory)`  
3. `count_by_status(Ticket)`  
4. `list_epics(..., limit: N)` — full rows  
5. `list_user_stories(..., limit: N)` — full rows  
6. `list_tickets(..., limit: N)` — full rows  
7. `list_tickets(..., status: "in_review", limit: N)` — full rows  

`recent_items/2` loads **3× N** full work-item rows, maps to thin summaries in Elixir, then sorts/`Enum.take(N)`. Payload and IO are ~3× larger than needed; merge-sort of “global recent” should be one SQL path (or three `select` of only key/title/status/updated_at + single sort).

Resource URI `project://status` always hits this path with no knobs to skip counts or recent.

---

## P1 — Domain list APIs unbounded when `limit` omitted

**Where:** `list_epics/2`, `list_user_stories/2`, `list_tickets/2`  
**Helper:** `maybe_limit(query, nil)` → **no SQL `LIMIT`**

MCP tools default `limit: 50` (max 100), but any direct/context call without `:limit` returns the **entire project table**. Defaults should hard-cap (e.g. 50–100, max 200) like boards/sprints/comments.

---

## P1 — `search_work_items/3`: leading-wildcard `ILIKE` × 3 tables

**Where:** `Projects.search_work_items/3`  
**Caller:** `MCP.Tools.SearchWorkItems`

```elixir
pattern = "%#{escape_like(q)}%"
# three queries: Epic | UserStory | Ticket
ilike(key | title | description, ^pattern)
```

Issues:

| Issue | Impact |
|--------|--------|
| Leading `%` | Cannot use B-tree indexes; sequential scan per table |
| `description` (`:text`) in OR | Forces large TOAST/heap reads |
| Three sequential queries | Latency ≈ sum of three scans |
| Per-table `limit` then `Enum.take(limit)` | Can pull up to **3× limit** rows before merge |
| Domain `limit` not capped | MCP max 50; domain accepts any integer |

No `pg_trgm` / GIN, no `tsvector`/full-text, no key-prefix fast path when `q` looks like an issue key.

---

## P1 — Unbounded association preloads on `get_*`

**Where:**

| Function | Preload | Risk |
|----------|---------|------|
| `get_epic/2` | `:user_stories` | All stories for epic, no limit |
| `get_user_story/2` | `:tickets`, `:epic` | All tickets for story |
| `get_ticket/2` | `:user_story`, `:subtasks`, `:worklogs` | All subtasks + worklogs |

MCP `get_*` tools and resources return these full graphs. Large epics/stories → large memory + JSON encode cost (`Helpers.encode_struct`).

`in_parallel: false` is fine; the problem is **no limit / no select subset**.

---

## P1 — Entity resolve over-fetches via `get_*` (ID-only need)

**Where:**

- `MCP.Tools.ListUserStories` → `get_epic` for `epic_key` (only needs `id`)  
- `MCP.Tools.ListTickets` → `get_user_story` for `story_key` (only needs `id`)  
- `MCP.Tools.ListComments` / `ListChangelog` → `get_epic` / `get_user_story` / `get_ticket` for entity id  

Each resolution preloads full associations (see above) then discards them. Under heavy list-by-key usage this multiplies IO for zero product value.

**Fix pattern:** lightweight `get_*_id_by_key/2` (single column select, no preload).

---

## P2 — Missing indexes for common ORDER BY / filter paths

**Migration:** `priv/repo/migrations/20260801200000_create_project_domain.exs`

Present (good): `(project_id, status)` on epics/stories/tickets; unique `key`; FKs.

**Missing relative to actual queries:**

| Query pattern | Suggested index |
|---------------|-----------------|
| `order_by: [desc: updated_at]` on epics/stories/tickets (`list_*`, `recent_items`) | `(project_id, updated_at DESC)` |
| `maybe_filter_assignee` on stories/tickets | `(project_id, assignee_email)` or `(project_id, assignee_email, status)` |
| `list_sprints` by `project_id` + optional `status` + `order_by inserted_at` | `(project_id, status)` or `(project_id, inserted_at DESC)` (standalone `status` index is weak) |
| `list_tickets` type filter with project | Prefer `(project_id, type)` over bare `type` |
| Comments: `project_id AND commentable_type AND commentable_id` | Composite `(project_id, commentable_type, commentable_id)` (or `(commentable_type, commentable_id, project_id)`) instead of two partial indexes alone |
| Changelogs: same pattern + `order_by inserted_at desc` | `(project_id, entity_type, entity_id, inserted_at DESC)` or `(entity_type, entity_id, inserted_at DESC)` |

Without `(project_id, updated_at)`, list + recent paths sort with index on status only when filtered, else file sort after project filter.

Bare `index(:tickets, [:type])` and `index(:sprints, [:status])` rarely help tenant-scoped queries.

---

## P2 — `list_changelog` domain limit uncapped

**Where:** `Collaboration.list_changelog/4`  
`limit = Keyword.get(opts, :limit, 50)` — **no `min(…, max)`**

MCP caps schema max 100; direct domain callers can pass arbitrary limit → large scans + memory.

Compare: `list_comments` uses `min(200)`.

---

## P2 — `list_comments` MCP has no limit parameter

**Where:** `MCP.Tools.ListComments`  
Always uses domain default (100, max 200). High-chatter entities always transfer up to 100 full comment bodies with no pagination/`offset`/cursor.

---

## P2 — Auth `touch_last_used` on every successful verify

**Where:** `Auth.verify_api_key/2` → `touch_last_used/1`  
**Plug:** `ElxMcpWeb.Plugs.McpAuth` (every MCP request)

Mitigations present: **60s debounce**, `update_all` by id (cheap). Remaining issues:

1. **Synchronous write** on the request path when debounce fires → extra latency + write load under multi-key traffic.  
2. **Read-then-maybe-write race**: concurrent requests with stale `last_used_at` can all pass the debounce check → multiple writes per window.  
3. Debounce is process-local knowledge only from the loaded row; no conditional `WHERE last_used_at IS NULL OR last_used_at < ^cutoff` in SQL (single atomic gate).

`fetch_active_key` always `preload: [:project]` — acceptable for auth scope; not the main cost.

---

## P2 — `list_api_keys/1` unbounded

**Where:** `Auth.list_api_keys/1`  
`Repo.all` for project with no limit. Low volume today; still an unbounded admin/list path.

---

## P3 — Parent-cycle walk is O(depth) queries

**Where:** `Projects.walk_creates_cycle?/4`  
One `Repo.get_by(Ticket, …)` per ancestor hop on ticket create. Fine for shallow trees; deep parent chains amplify write latency. Prefer recursive CTE / single ancestry query if depth grows.

---

## P3 — Search / list response encoding cost

MCP list tools `Enum.map(&Helpers.encode_struct/1)` on full schemas (including `metadata` maps, long descriptions). No field allowlist for list vs detail views → larger JSON and encode CPU than list UIs need.

---

## Issue inventory (quick)

| # | Sev | Area | Summary |
|---|-----|------|---------|
| 1 | P1 | status_summary | 7 queries; 3×N full-row over-fetch for recent |
| 2 | P1 | list_epics/stories/tickets | No default/max limit in domain |
| 3 | P1 | search_work_items | Leading `%` ILIKE ×3; text OR; no FTS/trgm |
| 4 | P1 | get_epic/story/ticket | Unbounded has_many preloads |
| 5 | P1 | MCP list tools resolve | get_* + preload only to resolve id |
| 6 | P2 | migrations | Missing (project_id, updated_at), assignee, composite polymorphic indexes |
| 7 | P2 | list_changelog | Domain limit uncapped |
| 8 | P2 | list_comments MCP | No limit/pagination control |
| 9 | P2 | auth touch_last_used | Sync write; non-atomic debounce |
| 10 | P2 | list_api_keys | Unbounded |
| 11 | P3 | parent cycle walk | N queries per depth |
| 12 | P3 | encode_struct lists | Full schema in list payloads |

---

## Suggested fix priority (not implemented)

1. Cap domain `list_*` / search limits; thin `select` for list/search.  
2. Collapse `status_summary` (counts + recent) into fewer queries; select only summary columns.  
3. Add `(project_id, updated_at DESC)` (+ assignee composites as needed).  
4. ID-only key lookups for list filters / comment-changelog resolve.  
5. Limit or paginate get_* association preloads (or separate “detail with children” API).  
6. Search: key exact/prefix path; consider `pg_trgm` GIN on title (and maybe description later); cap domain limit.  
7. Auth: SQL-gated debounce or async/sampled last_used updates.

---

*End of issues-only performance audit.*
