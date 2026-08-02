# Architecture Review — ElxMCP

**Scope:** `lib/elx_mcp/` (tenancy, projects, collaboration, auth, mcp), `lib/elx_mcp_web/` (router, plugs), `mix.exs`  
**Date:** 2026-08-01  
**xref context:** ~61 files; 2 cycles; top fan-out `mcp/server.ex` (17), `projects.ex` (9)

---

## Architecture score: **67 / 100**

| Factor | Notes | Impact |
|--------|--------|--------|
| Context split | Tenancy / Auth / Projects / Collaboration / Catalog / MCP is directionally sound | + |
| Scope usage | Reads take `%Auth.Scope{}`; writes take bare `project_id` — inconsistent, weakens 1.8 pattern | − |
| Boundary purity | Cross-context schema edges + direct `Repo` on foreign schema | − |
| Cycles | Schema-level Ticket ↔ Worklog (and graph cycles from associations) | − |
| API surface | Projects large; Collaboration/Projects writes half-wired; no update/delete | − |
| Web layer | Thin router + MCPAuth; no domain LiveViews | + |
| MCP layer | Tools go through contexts (good); Server is a fan-out registry | ~ |

---

## Issues (report only)

### 1. Cross-context schema cycle: Projects ↔ Collaboration

**Where:** `Projects.Ticket` `has_many :worklogs, ElxMcp.Collaboration.Worklog`; `Collaboration.Worklog` `belongs_to :ticket, Projects.Ticket`.

**Why it matters:** This is a compile-time / xref cycle between contexts. Ownership is unclear: time tracking lives in Collaboration but is embedded in the Projects ticket graph (`get_ticket` preloads `:worklogs`).

**Fix direction:** Prefer ID-only references from Collaboration → ticket_id without reverse `has_many` on Ticket; or move Worklog under Projects if time is part of the work-item aggregate. Load worklogs via `Collaboration` API, not Ticket preloads.

---

### 2. Collaboration reaches into Projects schemas via Repo

**Where:** `Collaboration.create_worklog/3` runs `from(t in Ticket, ...)` / `repo.update_all` on `ElxMcp.Projects.Ticket`.

**Why it matters:** Violates “contexts own their data.” Collaboration mutates Projects aggregate fields (`time_spent_seconds`) without going through `Projects`.

**Fix direction:** `Projects.inc_time_spent/3` (or Multi owned by Projects that accepts a worklog changeset), or a single Projects function that records worklog + increments.

---

### 3. Scope API is split-brain (reads vs writes)

**Where:**

| Context | Reads | Writes |
|---------|-------|--------|
| Projects | `%Scope{}` first | `project_id` first (`create_*`) |
| Collaboration | `%Scope{}` | `project_id` |
| Auth / Tenancy | n/a | `project_id` |

Moduledoc on `Projects` explicitly allows “`%Scope{}` **or** `project_id`.”

**Why it matters:** Phoenix 1.8 convention is scope-first for all tenant ops. Bare `project_id` invites callers to skip actor/scopes and makes authorization optional at the API boundary. Mix tasks and seeds are fine with internal helpers; public context API should not dual-path.

**Fix direction:** `create_*(%Scope{}, attrs)`; keep `project_id`-only helpers private or in admin/mix modules.

---

### 4. `project:write` is catalogued but not an architectural gate

**Where:** `Catalog.scopes/0` includes `project:write`; `Auth.verify_api_key/2` requires `"project:read"` only; no write path checks `Scope.has_scope?(..., "project:write")`.

**Why it matters:** Scope model is half-designed. Write functions accept any `project_id` with no actor/scopes. Future HTTP/MCP write tools will re-implement auth inconsistently.

**Fix direction:** Enforce scopes in context (or a single authorize helper) on every mutation; decide if verify should require read, write, or either.

---

### 5. Projects is a multi-aggregate context (fan-out 9, ~18 public fns)

**Public surface (`Projects`):**  
`create_board`, `list_boards`, `create_sprint`, `list_sprints`, `get_sprint`, `create_component`, `create_epic`, `list_epics`, `get_epic`, `create_user_story`, `list_user_stories`, `get_user_story`, `create_ticket`, `list_tickets`, `get_ticket`, `search_work_items`, `status_summary` — **17 public functions**, one module owns boards, sprints, components, epics, stories, tickets, search, and rollups.

**Why it matters:** Cohesion is “Jira domain,” not a single aggregate. Line count is under god-context (~364), but growth will force a split under pressure. Fan-out 9 is second only to MCP Server.

**Fix direction:** Split when write/update APIs land: e.g. `Projects.Boards`, `Projects.WorkItems` (epic/story/ticket), keep facade `Projects` if MCP needs a stable entrypoint.

---

### 6. Incomplete / dead domain surface

| Item | Evidence |
|------|----------|
| No update/delete | No `update_*` / `delete_*` in contexts |
| Components orphaned | `Component` / `ComponentLink` schemas; only `create_component/2`; no list/link/get |
| Collaboration writes unused by app layer | `create_comment`, `create_attachment`, `create_worklog`, `record_changelog` exist; MCP tools are read-only |
| Changelog never produced from domain events | `record_changelog` is fire-and-forget API; Projects mutations do not call it |

**Why it matters:** Schema/API surface implies a fuller product than the architecture delivers. Dead modules increase coupling noise (xref, migrations, mental load).

**Fix direction:** Wire changelogs into mutations via Multi, expose or delete ComponentLink until needed, mark write APIs as internal if MCP stays read-only.

---

### 7. Naming collision: `Projects` vs `Tenancy.Project`

**Where:** Context `ElxMcp.Projects` = work items; schema `ElxMcp.Tenancy.Project` = tenant.

**Why it matters:** Everyday language collapses both to “project.” Call sites and docs already say “project-scoped” for both tenant id and work-item context.

**Fix direction:** Rename context to `WorkItems` / `Issues` / `Tracker`, or rename tenant to `Workspace`/`Tenant` if product language allows. Document the distinction in moduledocs until rename.

---

### 8. Schemas cast tenant and association FKs

**Where:** e.g. `Projects.Ticket.changeset/2` casts `:project_id`, `:user_story_id`, `:parent_ticket_id`, `:board_id`, `:sprint_id` (similar patterns on other schemas).

**Why it matters:** Contexts set these fields, but casting them means any leak of raw attrs can re-tenant or re-parent. Architecture guideline: programmatically set FKs outside `cast`.

**Fix direction:** Drop FKs from `cast`; `put_change` / struct assignment in context only.

---

### 9. MCP.Server concentrator (fan-out 17)

**Where:** `ElxMcp.MCP.Server` registers 12 tools + 5 resources via `component/1`.

**Why it matters:** Expected for Anubis component registration; not a logic cycle. Still a single compile-time hub—every new tool edits Server.

**Fix direction:** Acceptable for now; if tool count grows, group by domain modules or codegen/registry list. Prefer keeping tools thin (already mostly true).

---

### 10. Polymorphic Collaboration IDs without entity ownership checks (write path)

**Where:** `create_comment` / `create_attachment` / `record_changelog` accept type+id (or free attrs) without verifying the target exists in `project_id`. MCP `list_comments` resolves keys via Projects (good); create path does not.

**Why it matters:** Cross-tenant or dangling entity references if writes open to untrusted callers.

**Fix direction:** Resolve entity through Projects (by key/id + scope) before insert.

---

### 11. Auth API surface small but authorization mixed into verification

**Public Auth:** `create_api_key/3`, `verify_api_key/2`, `revoke_api_key/1`, `get_api_key!/1`, `list_api_keys/1` (~5).

**Issue:** `verify_api_key` embeds `"project:read" in key.scopes` — authentication and minimum authorization are fused. Write-only or future scopes cannot authenticate.

**Fix direction:** Verify key+email+active only; check scopes at tool/context boundary via `Scope.has_scope?/2`.

---

### 12. Collaboration public API is write-heavy, read-thin

**Public:** `create_comment`, `list_comments`, `create_attachment`, `create_worklog`, `record_changelog`, `list_changelog` — **6 functions**.

No list attachments, no list worklogs, no get-by-id. Asymmetric vs schema set. Acceptable if intentional MVP; otherwise incomplete boundary.

---

## Clean areas (one line each)

- **Tenancy:** Small, cohesive (`Project` + issue key counter); no reverse deps into Projects/Collaboration logic.
- **Catalog:** Pure allowlists; appropriate shared leaf; no Repo.
- **Auth packaging:** `ApiKey` / `Scope` / `RateLimit` layout is clear; web only depends on Auth for MCP.
- **Web boundary:** Router + `MCPAuth` + CORS only; no domain LiveViews; business logic stays out of controllers.
- **MCP tools:** Call contexts (`Projects` / `Collaboration`), not `Repo`; Helpers centralize scope extraction.
- **mix.exs:** Standard Phoenix 1.8 app layout, single OTP app, sensible `precommit` alias; no multi-app umbrella complexity.
- **Intra-Projects associations:** Epic ↔ UserStory ↔ Ticket cycles are same-context graphs (expected), not boundary violations.

---

## Dependency sketch (intended vs actual)

```
Intended:
  Web/MCP → Auth, Projects, Collaboration, Tenancy
  Projects → Tenancy, Auth.Scope, Catalog
  Collaboration → Auth.Scope, Catalog  (+ ticket_id only)
  Auth → Tenancy, Catalog

Actual extras:
  Collaboration → Projects.Ticket (query + update)
  Projects.Ticket → Collaboration.Worklog (has_many)
  Projects → Tenancy.next_issue_key (OK)
```

---

## API surface summary

| Context | Public fns (approx) | Assessment |
|---------|---------------------|------------|
| **Projects** | 17 | Large multi-aggregate; split candidate |
| **Auth** | 5 (+ Scope helpers) | Right size; verify/authz coupling |
| **Collaboration** | 6 | Small; incomplete reads; write boundary soft |
| **Tenancy** | 5 | Right size |
| **Catalog** | ~10 getters | Fine as constants module |

---

## Priority order if fixing architecture

1. Break Ticket ↔ Worklog ownership cycle; stop Collaboration from updating Ticket via Repo.  
2. Unify context API on `%Scope{}` for tenant mutations; enforce `project:write` where applicable.  
3. Stop casting tenant/association FKs on schemas.  
4. Either wire Component/ComponentLink/changelog into real flows or quarantine/remove.  
5. Plan Projects split before update/delete APIs land.

---

## Score rationale (brief)

Starts from a healthy baseline (~80) for clear folders and thin web. Deducted for: cross-context cycle and Repo reach-in (−8), scope dual API + unused write scope (−6), Projects agglomeration / incomplete surfaces (−5), FK cast / naming friction (−4). **67** reflects “good skeleton, soft boundaries under load.”
