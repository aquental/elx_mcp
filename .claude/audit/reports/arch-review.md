# Architecture Review — ElxMCP
**Date:** 2026-08-02
**Score:** 74

## Summary

ElxMCP keeps a clear bounded-context layout (Tenancy / Auth / Projects / Collaboration / Catalog / MCP) with a thin web edge and MCP tools that consistently funnel through `Helpers.with_scope/2` into scope-filtered reads. Residual architecture debt is unchanged from the prior re-audit: dual Scope API (reads take `%Auth.Scope{}`, writes take bare `project_id`), `project:write` catalogued but never gated, `Projects` as a multi-aggregate hub (~433 LOC / 21 public fns), orphaned Component/ComponentLink surface, and two **runtime** xref cycles (Phoenix web stack + Epic↔UserStory↔Ticket associations). Ticket↔Worklog compile cycle remains fixed via one-way Worklog→Ticket and `Projects.increment_time_spent/3`. No compile-time cycles. Score holds at **74/C** — structure is sound for a read-first MCP status server; write-path and god-context risks block a B-grade.

## Score breakdown

| Criterion | Max | Score | Notes |
|-----------|-----|-------|-------|
| Context boundaries | 25 | 17 | Tenancy/Auth/Projects/Collaboration/Catalog/MCP split is clear; Collaboration→Projects for time_spent is correct; dual Scope API + ungated writes + polymorphic create without entity ownership checks hold the score down |
| Naming | 15 | 10 | Consistent `ElxMcp.*` / MCP Tools/Resources names; collision `Projects` (work items) vs `Tenancy.Project` (tenant) remains the main confusion |
| Fan-out | 15 | 13 | Tools/resources → Helpers → contexts (good); Server is registration hub (17 out); Projects 18 in / Helpers 17 in are expected concentrators |
| API surface | 15 | 9 | Projects 21 public (under 30 flag) but multi-aggregate + dead Component surface; Collaboration 6 asymmetric; almost no update/delete |
| No cycles | 15 | 12 | **0 compile cycles**; 2 runtime cycles (framework Layouts↔Router; Epic↔UserStory↔Ticket). Worklog cycle fixed |
| Folder structure | 15 | 13 | Standard context dirs + `mcp/{tools,resources}`; plugs under web; Component schemas present but unhooked from full API |
| **Total** | **100** | **74** | Same residual class as 2026-08-01 re-audit |

### Public function counts (context modules)

| Module | Public `def` | Lines | Bloat flag (>30) |
|--------|--------------|-------|------------------|
| `ElxMcp.Projects` | **21** | 433 | No (near multi-aggregate limit) |
| `ElxMcp.Collaboration` | **6** | 85 | No |
| `ElxMcp.Auth` | **6** | 132 | No |
| `ElxMcp.Tenancy` | **5** | 46 | No |
| `ElxMcp.Catalog` | **12** | 29 | No (allowlist module) |

### Xref cycles (`mix xref graph --format cycles`)

| Label | Result |
|-------|--------|
| Default / runtime | **2 cycles** |
| `--label compile` | **No cycles** |

1. **Runtime length 4 (framework):** `layouts.ex` → `page_controller.ex` → `endpoint.ex` → `router.ex` (standard Phoenix web cycle).
2. **Runtime length 3 (same-context assocs):** `projects/epic.ex` ↔ `user_story.ex` ↔ `ticket.ex` (`has_many`/`belongs_to` mutual refs).

### Scope pattern (reads vs writes)

| Context | Reads | Writes |
|---------|-------|--------|
| Projects | `%Scope{}` first (`list_*`, `get_*`, `search_*`, `status_summary`) | bare `project_id` (`create_*`, `update_ticket_parent`, `increment_time_spent`) |
| Collaboration | `%Scope{}` (`list_comments`, `list_changelog`) | bare `project_id` (`create_*`, `record_changelog`) |
| Auth / Tenancy | n/a | bare `project_id` / unscoped admin list |

Tenant isolation on **reads** is consistent (`where: project_id == ^scope.project_id`). **Writes** trust the caller-supplied `project_id` and do not thread actor/scopes; `project:write` is never checked.

### Cross-context call graph (who → whom)

```
MCP tools/resources → MCP.Helpers → Auth.Scope
                    → Projects (reads)
                    → Collaboration (list_comments, list_changelog)
                    → Projects (entity resolve for collab lists)

Collaboration → Projects.increment_time_spent/3  (write handoff, OK)
Projects      → Tenancy.next_issue_key/1         (key gen, OK)
Auth          → Catalog.scopes/0                 (allowlist, OK)
Schemas       → Tenancy.Project (belongs_to)     (FK, expected)
Worklog       → Projects.Ticket (belongs_to)     (one-way, cycle-safe)
```

No reverse cross-context Repo leaks (Collaboration no longer mutates Ticket via Repo).

### Fan-out: MCP → Helpers → contexts

- **12 tools + 5 resources** registered on `ElxMcp.MCP.Server`.
- Tools use `Helpers.with_scope/2` + context calls; resources use `Helpers.scope_from_frame/1`.
- Helpers also rebuilds Scope from flat assigns as fallback (dual path: `current_scope` preferred; `MCPAuth` sets both).

## Issues found

### P1

- `lib/elx_mcp/projects.ex:4-5,15-19` (and all `create_*` / `update_ticket_parent` / `increment_time_spent`) — **Scope dual API: writes take bare `project_id`** while moduledoc still allows “`%Scope{}` or `project_id`.” Callers can skip actor/scopes entirely. — Make mutations `create_*(%Scope{}, attrs)`; keep bare-id helpers private or mix/admin-only.

- `lib/elx_mcp/collaboration.ex:13-17,32-36,38-60,62-71` — **Same dual API on Collaboration writes**; create paths never see `%Scope{}`. — Align with Scope-first mutations; resolve entity ownership under tenant before insert.

- `lib/elx_mcp/catalog.ex:13` + `lib/elx_mcp/auth.ex:58` + absence of write checks — **`project:write` is catalogued but never enforced**; `verify_api_key/2` only requires `"project:read"`. Authn fused with minimum authz. — Authenticate key+email only; enforce `Scope.has_scope?/2` at tool/context mutation boundary.

### P2

- `lib/elx_mcp/projects.ex` (full module, ~433 LOC / 21 public) — **Multi-aggregate god-context** (boards, sprints, components, epics, stories, tickets, search, status). Under 30-fn flag but will force a painful split when update/delete expands. — Split before write surface grows: e.g. `Projects.Boards` / `Projects.WorkItems`, optional facade for MCP.

- `lib/elx_mcp/projects/component.ex`, `lib/elx_mcp/projects/component_link.ex`, `lib/elx_mcp/projects.ex:67-71` — **Dead/incomplete Component surface**: schemas + only `create_component/2`; no list/get/link API; `ComponentLink` unused outside its own module. — Wire full API or remove until needed.

- `lib/elx_mcp/projects/epic.ex:41`, `user_story.ex:47`, `board.ex:24`, `sprint.ex:29`, `component.ex:23`, `collaboration/{comment,attachment,worklog,changelog}.ex` cast lists — **Tenant/association FKs still in `cast`** (Ticket correctly uses `put_change` for `:project_id`/`:key` only). — Drop programmatic FKs from `cast`; set via context `put_change` only.

- `lib/elx_mcp/collaboration.ex:13-36,62-71` — **Polymorphic writes lack entity ownership checks** (type+id accepted without verifying target exists in `project_id`). MCP list path resolves keys via Projects (good); create path does not. — Resolve entity through Projects under scope before insert.

- `lib/elx_mcp/auth.ex:58` — **Authentication fused with `"project:read"` gate** — keys without read cannot authenticate; write-only scopes impossible. — Separate authn from scope checks (`Helpers` already re-checks read for tools).

### P3

- Naming: context `ElxMcp.Projects` vs schema `ElxMcp.Tenancy.Project` — everyday language collapses both to “project.” — Rename context to `WorkItems`/`Tracker` or tenant to `Workspace`/`Tenant`; document until rename.

- `lib/elx_mcp/collaboration.ex` public API — **Write-heavy, read-thin** (create attachment/worklog; no list/get for those). — Add list APIs or mark write helpers internal if MCP stays read-only.

- Domain mutations never call `record_changelog` — changelog is fire-and-forget / test-only; no domain event wiring. — Multi-insert changelog on mutations if audit trail is a product goal.

- `lib/elx_mcp/mcp/server.ex:12-30` — Server concentrator (xref out=17). Acceptable for Anubis registration; every new tool edits Server. — Registry list or domain grouping if tool count grows.

- `lib/elx_mcp/projects/epic.ex` ↔ `user_story.ex` ↔ `ticket.ex` — **Runtime association cycle** (same-context). Not a boundary violation; keeps `mix xref` noisy. — Accept, or break with string module names / drop reverse `has_many` if unused.

- `lib/elx_mcp_web/components/layouts.ex` ↔ router/endpoint/page_controller — **Framework Phoenix runtime cycle**. Do not “fix” unless upgrading framework patterns.

- Almost no general `update_*` / `delete_*` on work items (only `update_ticket_parent`) — API implies fuller product than delivered. — Explicitly document read-first MCP scope or implement full CRUD under Scope.

## Clean areas

- Context directory layout matches domain names; schemas live under owning context folders.
- MCP tools/resources stay thin and call contexts (no direct Repo in tools).
- `MCPAuth` assigns `%Scope{}` as `current_scope` and strips key/email headers after verify.
- Collaboration→Projects handoff for worklog time_spent (no cross-schema Repo mutation).
- Ticket no longer `has_many :worklogs` — compile cycle Ticket↔Worklog remains fixed.
- Catalog centralizes allowlists; Auth validates scopes against Catalog on key create.
- Application tree is minimal and correct: Telemetry, Repo, DNSCluster, PubSub, MCP.Server, Endpoint.
- Zero **compile-time** xref cycles.
- Router is thin: browser home + `/mcp` StreamableHTTP forward with CORS + MCPAuth.
- Read queries consistently pin `project_id` with `^` from Scope.
