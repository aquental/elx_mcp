# Performance Audit — ElxMCP

**Date:** 2026-08-02  
**Score:** 72  
**Grade:** C  
**Scope:** `lib/elx_mcp/projects.ex`, schemas, `collaboration.ex`, `mcp/` helpers+tools, `auth` rate limit, `priv/repo/migrations/`  
**Baseline:** 74/C (same residual class; re-scored against current code only)

---

## Summary

ElxMCP is an MCP read API over multi-tenant work items. There is **no classic N+1** (`Repo` inside `Enum.map` over query results). List paths have **default/max limits**, tenant-scoped filters, and useful **list indexes**. Residual risk is concentrated in three areas: **leading-wildcard `ILIKE` search across three tables** (no FTS/trgm), **unbounded `has_many` preloads on `get_*`**, and **list tools that only support `limit`** (no offset/cursor) while encoding full schemas. Auth uses an efficient **ETS fixed-window** limiter (single-node, no bucket GC). No heavy LiveViews → streams N/A with partial credit.

---

## Score breakdown

| Category | Max | Score | Notes |
|----------|-----|-------|--------|
| N+1 / multi-query | 30 | 25 | No Enum→Repo loops on reads; cycle walk O(depth); status_summary 7 sequential RTTs |
| Indexes | 20 | 14 | Strong `project_id`+status/updated_at/assignee; no search/trgm; weak collab composites |
| Preloads | 15 | 6 | Unbounded `:user_stories` / `:tickets` / `:subtasks` on get_*; list resolve still full get_* |
| GenServer / ETS | 15 | 12 | ETS rate limit is fine; no process bottleneck; no bucket cleanup; sync `last_used` write |
| LiveView streams | 10 | 8 | N/A (no collection LiveViews); partial credit |
| SELECT * / payload | 10 | 5 | Search/status slim `select`; lists/get encode full rows (+ assocs) |
| **Total** | **100** | **72** | |

---

## Issues found

### P1

1. **Leading-`%` ILIKE search × 3 tables (no FTS / trgm)**  
   - `lib/elx_mcp/projects.ex:246-283` (`search_work_items/3`)  
   - Caller: `lib/elx_mcp/mcp/tools/search_work_items.ex:21`  
   - Pattern `"%…%"` on `key | title | description` for epics, stories, tickets → B-tree unusable; text OR forces heap/TOAST reads; three sequential scans; per-table `limit` then `Enum.take` (up to 3× rows, no ranking).  
   - No `pg_trgm` GIN, no `tsvector`, no exact/prefix key fast path.

2. **Unbounded association preloads on `get_*`**  
   - `get_epic/2` → `Repo.preload(epic, [:user_stories], …)` — `projects.ex:105`  
   - `get_user_story/2` → `[:tickets, :epic]` — `projects.ex:159`  
   - `get_ticket/2` → `[:user_story, :subtasks]` — `projects.ex:242`  
   - MCP tools + resources encode full graph via `Helpers.encode_struct` (`get_epic.ex`, `get_user_story.ex`, `get_ticket.ex`, `mcp/resources/{epic,user_story,ticket}.ex`). Large epics/stories → memory + JSON without child cap.

3. **Comments / changelog resolve still loads full `get_*` (+ preloads) for `.id` only**  
   - `lib/elx_mcp/mcp/tools/list_comments.ex:39-58`  
   - `lib/elx_mcp/mcp/tools/list_changelog.ex:40-59`  
   - Uses `Projects.get_epic` / `get_user_story` / `get_ticket` instead of `get_epic_id` / `get_user_story_id` (and no `get_ticket_id`). Wastes association loads every list call.

### P2

4. **`status_summary/2` — 7 sequential round-trips**  
   - `lib/elx_mcp/projects.ex:289-354`  
   - Callers: `mcp/tools/project_status.ex:22`, `mcp/resources/project_status.ex:22`  
   - 3× `count_by_status` + 3× `recent_rows` + 1× `recent_tickets("in_review")`. Row shapes are slim (`select` maps); bottleneck is RTT fan-out, not payload. No parallelization / single CTE.

5. **List APIs: limit only — no offset/cursor pagination**  
   - Domain: `list_epics` `projects.ex:89-97`, `list_user_stories` `:141-151`, `list_tickets` `:223-234`, `list_boards` `:21-29`, `list_sprints` `:42-52`, `list_comments` `collaboration.ex:19-29`, `list_changelog` `:73-84`  
   - MCP list tools expose `limit` only. Clients cannot page past the first window.

6. **List payloads are full schemas (SELECT *)**  
   - MCP list tools → `Helpers.encode_struct/1` on full Ecto structs (e.g. `list_epics.ex:28`, `list_tickets.ex:25`, `list_user_stories.ex:24`).  
   - No list projection (`key/title/status/priority/updated_at`); includes `description`, `metadata`, labels, estimates.

7. **`list_changelog` domain limit uncapped**  
   - `lib/elx_mcp/collaboration.ex:74` — `Keyword.get(opts, :limit, 50)` without `min(..., max)`.  
   - MCP schema caps at 100 (`list_changelog.ex:15`); direct domain callers can pass arbitrary limit. Contrast `list_comments` (`min(200)` at `collaboration.ex:20`).

8. **`list_comments` MCP has no limit parameter**  
   - `lib/elx_mcp/mcp/tools/list_comments.ex:13-16` schema; always domain default 100 / max 200. No tool-level pagination control.

9. **Auth `touch_last_used` on request path**  
   - `lib/elx_mcp/auth.ex:60`, `119-131`  
   - 60s debounce + `update_all` by id. Still: sync write when debounce fires; read-then-write race under concurrency; no SQL gate `WHERE last_used_at IS NULL OR last_used_at < ^cutoff`.

10. **Index gaps vs query shapes**  
    - Present (good): `(project_id, status)` epics/stories/tickets; `(project_id, updated_at)` + assignee composites (`20260802000000_add_list_query_indexes.exs`); FK indexes on epic_id, user_story_id, parent_ticket_id, sprint_id.  
    - Missing:  
      - Search: trgm/GIN or FTS on title/description  
      - Comments: composite `(project_id, commentable_type, commentable_id, inserted_at)` — current `comments:project_id` + `(commentable_type, commentable_id)` (`create_project_domain.exs:188-189`)  
      - Changelogs: same pattern (`:244-245`)  
      - Sprints: tenant+status or tenant+`inserted_at` (only bare `sprints:status` at `:53`)  
      - Tickets type filter: prefer `(project_id, type)` over bare `tickets:type` (`:153`)

11. **Rate limiter ETS: no window GC; setup on every check; single-node**  
    - `lib/elx_mcp/auth/rate_limit.ex:12-50`  
    - Atomic `update_counter` is good. Old `{key, bucket}` tuples never deleted → unbounded ETS growth. `setup!()` on every `check/2`. Documented not multi-node-safe. Table created ad-hoc (not under Application supervision).

### P3

12. **Parent-cycle walk O(depth) queries**  
    - `lib/elx_mcp/projects.ex:375-394` — one `Repo.get_by(Ticket, …)` per ancestor hop on create/parent update. Prefer recursive CTE if depth grows.

13. **`ensure_same_project/3` loads full row for existence**  
    - `lib/elx_mcp/projects.ex:356-363` — used on create paths. `exists` / `select: true` cheaper under bulk create.

14. **Search merge bias**  
    - `projects.ex:283` — `(epics ++ stories ++ tickets) |> Enum.take(limit)` prefers epics then stories; tickets starved when earlier types fill the cap.

---

## Clean areas

- No `Repo.*` inside `Enum.map`/`for` over query results on read paths (encode-only maps).  
- `list_epics` / `list_user_stories` / `list_tickets` default limit 50, hard max 200 via `maybe_limit/2` (`projects.ex:421-425`).  
- `get_epic_id` / `get_user_story_id` used by list-filter tools (no preload for epic_key / story_key filters).  
- `status_summary` recent paths use thin `select` maps (not full structs).  
- Search domain hard-caps limit at 50; MCP schema max 50.  
- Indexes: `(project_id, updated_at)`, `(project_id, assignee_email)`, `(project_id, status)` on core work tables.  
- `list_api_keys/2` limited (`auth.ex:98-107`).  
- Rate limit uses atomic ETS `update_counter` with `read_concurrency` / `write_concurrency` (not a GenServer bottleneck).  
- `increment_time_spent` is a single `update_all` (`projects.ex:214-221`).  
- `next_issue_key` uses `FOR UPDATE` in a transaction (correct, write-path only).  
- No heavy LiveView collections (MCP-first app).  
- Tool telemetry duration emission available (`helpers.ex:67-97`) for future latency SLOs.

---

## Issue inventory

| # | Sev | Location | Summary |
|---|-----|----------|---------|
| 1 | P1 | `projects.ex:246-283` | Leading-% ILIKE ×3; no FTS/trgm |
| 2 | P1 | `projects.ex:105,159,242` | Unbounded has_many preloads on get_* |
| 3 | P1 | `list_comments.ex:39-58`, `list_changelog.ex:40-59` | Full get_* to resolve id |
| 4 | P2 | `projects.ex:289-354` | status_summary 7 sequential queries |
| 5 | P2 | all `list_*` | No offset/cursor pagination |
| 6 | P2 | MCP list tools | Full-schema encode |
| 7 | P2 | `collaboration.ex:74` | list_changelog limit uncapped |
| 8 | P2 | `list_comments.ex` | No MCP limit param |
| 9 | P2 | `auth.ex:119-131` | Sync touch_last_used |
| 10 | P2 | migrations | Collab composites; tenant type/status; search indexes |
| 11 | P2 | `rate_limit.ex` | No ETS bucket GC; single-node |
| 12 | P3 | `projects.ex:375-394` | Cycle walk N queries |
| 13 | P3 | `projects.ex:356-363` | Full-row existence check |
| 14 | P3 | `projects.ex:283` | Search type-order bias |

---

## Suggested fix priority (not implemented)

1. Search: key exact/prefix path; FTS or `pg_trgm` GIN on title; optional description; keep hard cap.  
2. Cap or paginate `get_*` association preloads (or split “detail vs children list”).  
3. Wire comments/changelog to `get_*_id` (+ add `get_ticket_id`).  
4. Collapse or parallelize `status_summary` round-trips.  
5. List projection selects; optional offset/cursor.  
6. Cap `list_changelog`; expose limit on `list_comments`.  
7. Collaboration composite indexes; SQL-gated or async `last_used_at`; periodic ETS bucket prune.

---

*End of performance audit. No application code changed.*
