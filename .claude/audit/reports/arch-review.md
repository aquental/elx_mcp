# Architecture Review — ElxMCP

**Date:** 2026-08-02  
**Scope:** `lib/elx_mcp/`, `lib/elx_mcp_web/`, `config/`, `mix.exs`  
**Phoenix:** 1.8.9 · **Ash:** not present

## Architecture score: 71 / 100

| Criterion | Max | Score | Deduction rationale |
|-----------|-----|-------|---------------------|
| Context boundaries | 25 | 15 | Collaboration queries/mutates Projects schemas; Auth hydrates `Tenancy.Project` outside Tenancy API; Worklog `belongs_to` Ticket |
| Naming | 15 | 11 | `Projects` (work-item context) vs `Tenancy.Project` (tenant root) name collision |
| Fan-out | 15 | 12 | Hub concentration: `Projects` (17 in) + `MCP.Helpers` (17 in); Collaboration fans out to foreign schemas |
| API surface | 15 | 9 | God context `Projects` 711 LOC / 22 public defs; orphan ComponentLink; unscoped/unused `increment_time_spent/3` |
| No cycles | 15 | 12 | Compile cycles: **0**. Runtime: Epic↔UserStory↔Ticket assoc cycle; Phoenix Layouts↔Router↔Endpoint (framework noise) |
| Folder structure | 15 | 12 | Schemas present without context API (`ComponentLink`); domain search/status helpers inflate single context file |
| **Total** | **100** | **71** | |

**Clean (one-liners):** MCP tools/resources correctly sit behind contexts (no direct Repo); web edge is thin (plugs + home controller); compile-time DAG has no cycles; config layout standard; no services/repositories/commands anti-pattern folders.

---

## Findings

### P1 — Cross-context schema access & mutation

**Collaboration reaches into Projects ownership**

- **File:** `lib/elx_mcp/collaboration.ex`
- **Issue:** `ensure_entity_in_project/3` and `exists_in_project?/3` query `ElxMcp.Projects.{Epic,UserStory,Ticket}` via `Repo.get_by/2`. Contexts must not query another context’s schemas.
- **Also:** `create_worklog/3` runs `Repo.update_all` on `Ticket` (`time_spent_seconds`) inside `Ecto.Multi`, mutating Projects-owned data in place.

```elixir
# collaboration.ex — boundary leak
alias ElxMcp.Projects.{Epic, Ticket, UserStory}
# ...
from(t in Ticket, where: t.id == ^ticket_id and t.project_id == ^project_id)
|> Repo.update_all(inc: [time_spent_seconds: worklog.time_spent_seconds])
```

- **Related dead/misaligned API:** `ElxMcp.Projects.increment_time_spent/3` (`lib/elx_mcp/projects.ex:332`) exists for this purpose but has **zero callers** in `lib/` or `test/`. Collaboration reimplements the write instead of calling Projects.

**Worklog schema association crosses contexts**

- **File:** `lib/elx_mcp/collaboration/worklog.ex`
- **Issue:** `belongs_to :ticket, ElxMcp.Projects.Ticket` couples Collaboration schema compile graph to Projects. Ticket intentionally omits reverse `has_many :worklogs` (comment in `ticket.ex`) to avoid a *compile* cycle — confirms the coupling is known debt.

**Auth hydrates tenant outside Tenancy**

- **File:** `lib/elx_mcp/auth.ex` (`load_project/1`, `load_project_struct/1`)
- **Issue:** Uses the same SECURITY DEFINER SQL as `Tenancy.get_project/1` (`elx_mcp_get_project`) but rebuilds `%ElxMcp.Tenancy.Project{}` locally. Duplicates `uuid_param/1`, `cast_uuid/1`, `load_project_struct/1` with `lib/elx_mcp/tenancy.ex`. Should call `Tenancy.get_project/1` (or a shared internal loader owned by Tenancy).

---

### P2 — God context & incomplete domain surface

**`ElxMcp.Projects` exceeds healthy context size**

- **File:** `lib/elx_mcp/projects.ex` (**711 LOC**, **22 public `def`s**)
- **Issue:** Single module owns boards, sprints, components, epics, user stories, tickets, parent-cycle walks, full-text-ish search, and status summary. Crosses the ~400-line multi-aggregate split threshold. Highest fan-in in the app (17 callers via MCP tools/resources).
- **Split candidates (by aggregate):** `Projects.Boards` / `Projects.Sprints`, `Projects.WorkItems` (epic/story/ticket), `Projects.Search` (or query module under `projects/`).

**Orphan / incomplete Component API**

- **Files:** `lib/elx_mcp/projects/component.ex`, `lib/elx_mcp/projects/component_link.ex`
- **Issue:** `create_component/2` exists; no `list_components`, no link/unlink API for `ComponentLink`. Schema + migrations + RLS exist; context surface does not. Dead domain surface relative to folder structure.

**Unscoped public mutator**

- **File:** `lib/elx_mcp/projects.ex` — `increment_time_spent(project_id, ticket_id, seconds)`
- **Issue:** Only public Projects write that takes raw `project_id` instead of `%Auth.Scope{}` (and is unused). Either wire Collaboration through it (with scope/auth) or make it private/`@doc false` internal.

---

### P2 — Naming collision

**`Projects` vs `Tenancy.Project`**

- **Files:** `lib/elx_mcp/projects.ex`, `lib/elx_mcp/tenancy/project.ex`
- **Issue:** Context named `Projects` holds work items; tenant root is `Tenancy.Project`. Readers confuse “project” (tenant) with “projects context” (epics/tickets). Prefer renaming work-item context (`WorkItems`, `Backlog`, `Tracker`) or tenant schema (`Tenant` / keep under Tenancy but avoid sibling name `Projects`).

---

### P3 — Runtime dependency cycles

**Schema association cycle (runtime)**

- **Files:** `lib/elx_mcp/projects/epic.ex` ↔ `user_story.ex` ↔ `ticket.ex`
- **Evidence:** `mix xref graph --format cycles` → cycle of length 3 among these three.
- **Impact:** Not a compile cycle (associations use module atoms / full names carefully), but runtime graph cycles complicate xref analysis and future compile-time refactoring. Prefer ID-only FKs without bidirectional `has_many` where preloads always go through context queries.

**Phoenix web cycle (noise)**

- **Files:** `layouts.ex` ↔ `page_controller.ex` ↔ `endpoint.ex` ↔ `router.ex`
- **Evidence:** same `mix xref graph --format cycles` (length 4). Standard Phoenix wiring; do not “fix” unless refactoring away verified routes/layout hooks.

**Compile cycles:** `mix xref graph --format cycles --label compile` → **No cycles found**. Good.

---

### P3 — Fan-out / hub modules

| Module | Outgoing | Incoming | Note |
|--------|----------|----------|------|
| `mcp/server.ex` | 17 (all deps) | low | Expected component registry |
| `projects.ex` | 10 | **17** | Hub; every MCP tool/resource |
| `mcp/helpers.ex` | — | **17** | Scope/JSON concentrator (OK for adapter layer) |
| `collaboration.ex` | 10 | 2 | Inflated by foreign schema deps |
| `tenancy/project.ex` | — | 13 | Shared FK target (expected) |
| `catalog.ex` | — | 11 | Shared allowlists (OK) |

No additional fan-out crisis beyond Projects hub + Collaboration cross-context edges already scored under boundaries.

---

### P3 — Folder structure vs conventions

| Area | Status |
|------|--------|
| `lib/elx_mcp/{context}.ex` + `{context}/` schemas | Matches Phoenix context convention |
| `lib/elx_mcp/mcp/{tools,resources}` | Sound adapter layer (not a domain context; no `mcp.ex` facade needed) |
| `lib/elx_mcp_web/{plugs,controllers,components}` | Thin edge; MCP auth in plug |
| `config/*` | Standard Phoenix split |
| Incomplete: `ComponentLink` schema without context API | Structural drift |
| `Catalog` at app root | Acceptable shared constants module (not a bounded context) |

---

## Dependency DAG (contexts, as implemented)

```
MCP tools/resources → MCP.Helpers (Scope from frame)
                   → Projects (reads / id resolve)
                   → Collaboration (list comments/changelog)
                         ↳ Projects schemas via Repo  ← P1 leak
                         ↳ mutates Ticket rows        ← P1 leak

Collaboration → Auth.authorize_write / Scope
Projects      → Auth.authorize_write / Scope
              → Tenancy.next_issue_key/1
Auth          → Catalog; Tenancy.Project schema (+ duplicated project load)
Schemas       → Tenancy.Project (belongs_to)
Worklog       → Projects.Ticket (belongs_to)
```

---

## Evidence commands

```text
mix xref graph --format stats
  → 62 nodes; Cycles: 2; top in: projects.ex (17), mcp/helpers.ex (17)

mix xref graph --format cycles --label compile
  → No cycles found

mix xref graph --format cycles
  → Epic↔UserStory↔Ticket; Layouts↔Router↔Endpoint

wc -l lib/elx_mcp/projects.ex
  → 711

grep -rn increment_time_spent lib test
  → definition only (no callers)
```

---

## Recommended order of remediation

1. **P1:** Collaboration existence checks + worklog time rollup go through `Projects` public API (add `entity_in_project?/3` or `get_*_id`-style helpers; call scoped `increment_time_spent`).
2. **P1:** Auth project load → `Tenancy.get_project/1`; delete duplicated struct loaders.
3. **P2:** Split `Projects` by aggregate before more write/MCP surface lands.
4. **P2:** Either implement ComponentLink context API or stop shipping orphan schema as “done.”
5. **P2/P3:** Rename work-item context to reduce `Project`/`Projects` confusion; drop bidirectional schema assocs where context queries suffice.

SCORE: 71
