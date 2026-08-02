# Architecture Review — ElxMCP

**Date:** 2026-08-02  
**Score:** 76 / 100

## Summary

Context layout (Tenancy / Auth / Projects / Collaboration / Catalog / MCP) and thin web edge remain sound. Prior dual-API write gap is **fixed**: mutations take `%Auth.Scope{}` and call `Auth.authorize_write/1`. Residual debt is **Projects god-module growth** (~655 LOC), **schema boundary leaks** (Collaboration → Projects schemas), **orphaned Component surface**, and **runtime association cycles**. No compile-time cycles. Grade **C+** — structure OK for read-first MCP; split Projects before write/MCP expansion.

## Score breakdown

| Criterion | Max | Score | Deductions |
|-----------|-----|-------|------------|
| Context boundaries | 25 | 18 | −4 Collaboration queries `Projects.{Epic,Ticket,UserStory}` via Repo; −3 multi-aggregate god context |
| Naming | 15 | 11 | −4 `Projects` (work items) vs `Tenancy.Project` (tenant) collision |
| Fan-out | 15 | 13 | −2 all MCP tools + collab resolve funnel into `Projects` hub |
| API surface | 15 | 10 | −3 `increment_time_spent/3` unscoped public; −2 Component create-only / ComponentLink dead; no update/delete surface |
| No cycles | 15 | 12 | −3 runtime Epic↔UserStory↔Ticket; Worklog→Ticket one-way (compile OK) |
| Folder structure | 15 | 12 | −2 Component schemas in tree without full context API; search helpers inflate single file |
| **Total** | **100** | **76** | Prior dual-Scope P1 closed; Projects LOC ↑ |

### Module sizes

| Module | Public `def` | LOC | Flag |
|--------|--------------|-----|------|
| `ElxMcp.Projects` | 22 | **~655** | **God context** (>400 multi-aggregate) |
| `ElxMcp.Collaboration` | 6 | ~152 | OK |
| `ElxMcp.Auth` | 7 | ~139 | OK |
| `ElxMcp.Tenancy` | 5 | ~46 | OK |
| `ElxMcp.Catalog` | 12 | ~29 | OK (allowlists) |
| `ElxMcp.MCP.Helpers` | ~8 | ~130 | OK concentrator |

### Dependency DAG (contexts)

```
MCP tools/resources → Helpers → Auth.Scope
                   → Projects (reads)
                   → Collaboration (lists) + Projects (id resolve)

Collaboration → Auth, Projects.increment_time_spent/3
              → Projects schemas (Repo existence checks)  ← boundary leak
Projects      → Auth, Tenancy.next_issue_key/1
Auth          → Catalog
Schemas       → Tenancy.Project (belongs_to FK)
Worklog       → Projects.Ticket (belongs_to, one-way)
```

Compile cycles: **none** (Ticket omits `has_many :worklogs` intentionally).  
Runtime cycles: framework Layouts↔Router (noise); Epic↔UserStory↔Ticket assoc graph.

---

## Issues found

### P1

- **`lib/elx_mcp/projects.ex` (~655 LOC, 22 public fns)** — Single context owns boards, sprints, components, epics, stories, tickets, search, and status aggregates. Search alone triples Epic/UserStory/Ticket query patterns thrice. Growth since prior audit (~433 → ~655). Split along aggregates (e.g. `Projects.Boards`, `Projects.WorkItems`, `Projects.Search`) or extract private query modules before adding write tools.

- **`lib/elx_mcp/collaboration.ex:15,131-146`** — Cross-context schema reach: `alias ElxMcp.Projects.{Epic, Ticket, UserStory}` + `Repo.get_by/2` for entity ownership. Violates “contexts own their data.” Prefer `Projects.entity_in_project?/3` (or scoped get_id) so Collaboration never imports Projects schemas.

### P2

- **`Projects.increment_time_spent/3` (`projects.ex:293`)** — Public API takes bare `project_id`, no Scope/authorize. Safe today only because Collaboration already authorized; any other caller bypasses write gate. Make private or require `%Scope{}`.

- **`Component` / `ComponentLink` half-surface** — Schema + `create_component/2` only; no list/get/link API, no MCP tool. Dead domain weight inside Projects folder. Complete API or drop until needed.

- **Asymmetric mutation surface** — Many `create_*` + one `update_ticket_parent`; no general update/delete for work items. Fine for read-MCP today; incomplete for future write tools / admin UI.

- **Runtime assoc cycle** `Epic` ↔ `UserStory` ↔ `Ticket` (`has_many`/`belongs_to`). Same-context only; no compile break yet. Prefer id-only refs at edges if modules keep growing.

### P3

- **Naming collision** — `ElxMcp.Projects` vs `ElxMcp.Tenancy.Project` confuses “tenant project” vs “work-item context.” Consider `WorkItems` / `Issues` rename when splitting.

- **`MCP.Helpers.scope_from_frame/1` dual path** — Rebuilds Scope from flat assigns if `current_scope` missing. Plug sets both; keep single path to avoid silent drift.

---

## Clean areas (one line each)

- **Auth** — Scope struct, API-key verify, `authorize_write/1`, rate limit + session bind: coherent and small.
- **Tenancy** — Thin project CRUD + atomic `next_issue_key/1`; no overreach.
- **Catalog** — Shared allowlists; no Repo; correctly consumed by Auth/schemas.
- **MCP layer** — Tools/resources call contexts only; no direct Repo; Server is pure registration hub.
- **Web edge** — Router thin; `:mcp` pipeline (CORS + MCPAuth); no LiveView product surface.
- **Tenant isolation on reads** — Queries pin `project_id` from Scope; child preloads re-filter by tenant.

---

## Residual improvements (positive only)

- P1 residual: **split `Projects` before it grows past ~700 LOC**; close Collaboration→schema leak with a Projects existence API.
