# Plan: ElxMCP Audit Remediation

**Status**: COMPLETED (implemented 2026-08-01; 45 tests pass)  
**Created**: 2026-08-01  
**Detail Level**: standard  
**Input**: `/phx:audit` → `.claude/audit/summaries/project-health-2026-08-01.md` (score 66/D)

## Summary

Close the gaps that pulled the health score to **66/D**: prod DB TLS defaults, unbounded/expensive reads, false cycle test, Ticket↔Worklog cycle, Scope-first writes, MCP test coverage, rate-limit/session hardening, and Anubis LGPL / deps audit hygiene.

Target after this plan: raise audit to **~B (80+)** on a re-run of `/phx:audit` (trend within project only).

## Scope

**In Scope (from audit Immediate + Short-term):**

1. Prod-safe `DB_SSL` defaults  
2. Default limits + thinner ID lookups for lists/search/status  
3. Real cycle detection test (+ ensure create path can hit cycle error)  
4. Break Ticket ↔ Worklog compile cycle  
5. Mutations take `%Scope{}` / `put_change` project_id (no cast from client)  
6. MCP tool/resource tests + auth E2E smoke where feasible  
7. Rate limit + session notes / light hardening  
8. LGPL NOTICE + optional `mix_audit` in precommit  
9. Indexes for common list filters  

**Out of Scope (Long-term / later plan):**

- Full `Projects` context split  
- pg_trgm / FTS search redesign  
- Completing Component write UI / removing dead surface entirely  
- Multi-node distributed rate limiter (document only unless cheap)

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Prod SSL default | `DB_SSL` default `verify_none` only for dev/test; **prod requires** `true` or explicit `verify_none` with log warn | Audit P0 |
| List defaults | Default `limit: 50`, max 200 when omitted | Perf + DoS |
| ID resolve | Private `fetch_*_id/2` without heavy preload | Stop waste on list filters |
| Cycle break | Drop `has_many :worklogs` from Ticket **or** update time via `Projects.touch_time_spent/2` only | Prefer Projects API for ticket aggregate |
| Mutations | `create_*(%Scope{} \| project_id, attrs)` → prefer Scope; put_change `project_id` | Latent IDOR |
| Cycle test | Create A→B, then try to set parent that closes cycle if API allows; else document unit test on `walk_creates_cycle?` via public create that would cycle | Must assert `{:error, :cycle_detected}` |
| LGPL | Add root `LICENSE`/`NOTICE` + README Anubis section | Compliance |

## Module Structure (touches)

```
config/runtime.exs
lib/elx_mcp/projects.ex
lib/elx_mcp/projects/ticket.ex
lib/elx_mcp/collaboration.ex
lib/elx_mcp/auth/rate_limit.ex
lib/elx_mcp/mcp/tools/*.ex (limits / resolve)
lib/elx_mcp/mcp/server.ex (session notes if API allows)
test/elx_mcp/*
NOTICE / LICENSE / README / mix.exs (audit alias)
priv/repo/migrations/*_add_list_indexes.exs
```

## Phase 1: Security defaults + correctness tests [PENDING]

- [ ] [P1-T1][security] Prod DB SSL: in `runtime.exs`, when `config_env() == :prod`, default `DB_SSL` to `true` (or require explicit env); never default prod to `verify_none`. Dev/test keep `verify_none` via `.env`. Document in `.env.example`.

- [ ] [P1-T2][test] Fix cycle coverage in `projects_test.exs`: assert real `{:error, :cycle_detected}` (implement missing update-parent path if create-only cannot form a cycle; e.g. try create with self-parent or parent chain that loops if supported).

- [ ] [P1-T3][test] Auth/rate-limit: unit test 429 path (low limit in test) or extract check and unit-test RateLimit.

## Phase 2: Performance — lists, search, status [PENDING]

- [ ] [P2-T1][ecto] Default limits on domain `list_epics/list_user_stories/list_tickets/list_sprints/list_boards/list_api_keys` when `:limit` omitted (50/max 200). MCP tools already pass limits — domain must not be unbounded for other callers.

- [ ] [P2-T2][ecto] Add lightweight `get_*_id_by_key(scope, key)` (no preload) used by list filter resolve (epic_key/story_key). Keep full `get_*` for detail tools only.

- [ ] [P2-T3][ecto] Slim `status_summary`: single/grouped counts; recent query with `select` of key/title/status/updated_at only + SQL `ORDER BY updated_at DESC LIMIT n` (union or three limited selects + merge) instead of full structs ×3.

- [ ] [P2-T4][ecto] Migration: indexes `(project_id, updated_at)` on epics/user_stories/tickets; optional `(project_id, assignee_email)` if filters used. Document that leading-wildcard ILIKE remains seq-scan until FTS (out of scope).

- [ ] [P2-T5][direct] Cap `search_work_items` hard max limit (e.g. 50); consider `prefix` search option later — not full FTS in this plan.

## Phase 3: Architecture — cycle + Scope writes [PENDING]

- [ ] [P3-T1][ecto] Break Ticket↔Worklog cycle: remove `has_many :worklogs` from Ticket; keep `belongs_to :ticket` on Worklog. Worklog create updates ticket via `Projects.increment_time_spent(project_id, ticket_id, seconds)` (or Multi only on Ticket schema without reverse assoc).

- [ ] [P3-T2][ecto] Mutations: stop casting `project_id` (and server-owned keys) on schemas used for create; use `put_change` in contexts. Prefer first-arg `%Scope{}` for creates used from future write tools; keep `project_id` overload for mix/seeds if needed but mark private/internal.

- [ ] [P3-T3][direct] `mix xref graph --format cycles` → 0 cycles (or document remaining Phoenix-generated only).

## Phase 4: Security ops + deps hygiene [PENDING]

- [ ] [P4-T1][security] RateLimit: document single-node; make check atomic with `:ets.update_counter` pattern or serialize inserts; optional per-key bucket after auth (post-auth plug or Auth.verify).

- [ ] [P4-T2][security] If Anubis supports `serialize_assigns` / session metadata: persist only `api_key_id` + `project_id`; re-validate on request. Else document residual risk in README Security notes.

- [ ] [P4-T3][direct] Add `NOTICE` (Anubis LGPL) + root license clarification; README Dependencies section. Optionally add `{:mix_audit, ...}` or document `mix hex.audit` in `precommit`.

- [ ] [P4-T4][direct] Align `elixir: "~> 1.17"` vs Anubis 1.18 requirement — verify Hex metadata; bump if required.

## Phase 5: Tests + verification [PENDING]

- [ ] [P5-T1][test] Tools: GetUserStory, ListUserStories, ListSprints, ListComments, ListChangelog + not-found paths.

- [ ] [P5-T2][test] At least one Resource `read/2` test (ProjectStatus or Epic) with Frame + Scope.

- [ ] [P5-T3][test] Domain limit defaults (omit limit → length ≤ 50 when many fixtures).

- [ ] [P5-T4][test] Run `mix precommit`; re-run targeted audit pulse (`mix xref cycles`, `mix test`).

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking seeds/create APIs by Scope-only | Keep project_id helpers for Mix/seeds |
| Cycle hard to form with create-only API | Add `update_ticket_parent/3` internal or test private via create chain if possible |
| Anubis session API limited | Document if bind not available |
| Index migration on live DB | Use concurrent index only if needed; small MVP tables OK |

## Session Handoff

- Auth: `verify_api_key(key, email)` + headers `X-API-Key` / `X-Email`  
- Audit reports under `.claude/audit/reports/`  
- Do not re-introduce hardcoded DB credentials  

## Verification Checklist

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix format --check-formatted`
- [ ] `mix test` (all green)
- [ ] `mix precommit`
- [ ] `mix xref graph --format cycles` improved
- [ ] Prod path: missing `DB_SSL` does not default to `verify_none` silently

## Mapping audit → tasks

| Audit item | Task |
|------------|------|
| DB_SSL prod | P1-T1 |
| Cycle test false | P1-T2 |
| Unbounded lists / search / status | P2-T1..T5 |
| Ticket↔Worklog cycle | P3-T1 |
| Scope dual API / cast project_id | P3-T2 |
| Rate limit / session | P4-T1, P4-T2 |
| LGPL / mix_audit / elixir | P4-T3, P4-T4 |
| MCP tests / E2E | P5-T1, P5-T2 |
