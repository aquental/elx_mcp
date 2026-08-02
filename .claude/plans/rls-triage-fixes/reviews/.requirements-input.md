# Plan: RLS triage fixes (review → triage)

**Status**: COMPLETE  
**Created**: 2026-08-02  
**Detail Level**: standard  
**Input**: `.claude/plans/review/reviews/review-triage.md`  
**Source review**: `.claude/plans/review/reviews/rls-p1-remediation-review.md`

## Summary

Fix all 5 review blockers and 14 warnings from the RLS/P1 remediation review. Priorities: restore `with_tenant` changeset error contract, redesign RLS so bypass is not a client-settable GUC (SECDEF owner with `BYPASSRLS`), harden pool/process hygiene, tighten auth/collab API surface, then lock behavior with tests.

## Scope

**In Scope:**

- All triage Fix Queue items (B1–B5, W1–W14)
- Cheap suggestions that land while fixing (empty scopes, ESCAPE, VOLATILE if rewriting funcs)
- Migration(s) + `spec/DB_SEC.md` update for new RLS model
- Tests for nested tenant, collab gates, SECDEF-in-TX isolation, search rank/escape

**Out of Scope:**

- LiveView / MCP write tools
- Network / hermes `pg_hba` / aquental residual ops (DB_SEC § other)
- Full RLS matrix on every table for UPDATE/DELETE (sample expansion only — W14)
- Production secret manager migration

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| RLS bypass model | **Remove `app.bypass_rls` from policies**; SECDEF helpers owned by role with `BYPASSRLS` | Client-settable GUC is not a security boundary (B2); multi-agent consensus |
| SECDEF leak (B3) | Fixed primarily by B2; no policy hatch remains | SET LOCAL on removed GUC becomes irrelevant for isolation |
| `with_tenant` clear (B1) | **Do not** run clear SQL after `fun` when it would run in an aborted TX; rely on SET LOCAL end-of-TX + clear process dict in `after` | LOCAL GUC ends with COMMIT/ROLLBACK; clear after error raises |
| Pool hygiene (W2) | `after_connect` sets `app.project_id=''` (and drop bypass usage) | Defense if session-level set ever happens |
| `increment_time_spent` (W3) | Keep public for Multi use; mark `@doc false` + `@moduledoc` note; **do not** add Scope (would break nested Multi under tenant) | Collab already authorizes; tests cover boundary |
| Attachment path (W4) | Remove `:storage_path` from cast; set server-side in `create_attachment` under tenant-prefixed path | Prevent path injection when downloads land |
| Migration `down` (W7) | Prefer implementable `down` that restores prior policy shape **or** explicit `@moduledoc` irreversible + empty down documented | Ops clarity |
| EXECUTE grants (W1) | `REVOKE ALL FROM PUBLIC`; `GRANT EXECUTE` only to app role (`elx_mcp_dev` / config role) | Least privilege |

## Data Model

No new tables. Changes:

1. **Policies** on `projects`, tenant tables, `component_links`: drop `app.bypass_rls` branch; keep UUID GUC match only.
2. **SECURITY DEFINER functions** (`elx_mcp_*`): re-own to role with `BYPASSRLS` (or `ALTER FUNCTION … OWNER TO`), remove in-body `set_config('app.bypass_rls',…)` if no longer needed, `SET search_path = public`, VOLATILE where they mutate/set, least-privilege EXECUTE.
3. Optional new DB role e.g. `elx_mcp_secdef` with `BYPASSRLS NOSUPERUSER` — created in migration if cluster allows (app role is not superuser). **Spike** if migrator cannot CREATE ROLE: document manual DDL on hermes + migration that only alters ownership when role exists.

## Module Structure

No new Elixir modules. Touch:

| Module | Change |
|--------|--------|
| `ElxMcp.Repo` | B1, W2, W5 — with_tenant hygiene + after_connect |
| `ElxMcp.Auth` | W6, W8, empty scopes |
| `ElxMcp.Tenancy` | W6 load via Repo.load |
| `ElxMcp.Projects` | W3 doc false on increment; search ESCAPE if needed |
| `ElxMcp.Collaboration` | W4 storage_path; W9 limit clamp |
| `ElxMcp.Collaboration.Attachment` | W4 cast |
| Migrations | B2, B3, W1, W7 |
| Tests | B4, B5, W10–W14 + B1/B3 regressions |
| `spec/DB_SEC.md` | Document new RLS model |

## Completeness (review → plan map)

| Finding | Task(s) |
|---------|---------|
| B1 with_tenant clear | P1-T1 |
| B2 client bypass GUC | P2-T1, P2-T2 |
| B3 SECDEF outer TX leak | P2-T1 (primary), P3-T1 regression |
| B4 nested with_tenant tests | P3-T1 |
| B5 collab boundary tests | P3-T2 |
| W1 GRANT PUBLIC | P2-T1 |
| W2 after_connect | P1-T2 |
| W3 unscoped APIs | P1-T3 |
| W4 storage_path | P1-T4 |
| W5 process dict | P1-T1 |
| W6 hand-built structs | P1-T5 |
| W7 migration down | P2-T1 |
| W8 nil project | P1-T5 |
| W9 limit clamps | P1-T4 |
| W10 search tests | P3-T3 |
| W11 ensure_entity tests | P3-T3 |
| W12 increment rollback tests | P3-T2 |
| W13 attachment isolation | P3-T2 |
| W14 RLS sample expand | P3-T1 |

---

## Phase 0: Spike [DONE]

- [x] [P0-T1][security] Confirm CREATE ROLE / BYPASSRLS on hermes as migration role — **path (b)**: `elx_mcp_dev` cannot CREATE ROLE; manual SQL in `priv/repo/manual/create_elx_mcp_secdef_role.sql`; CI auto-creates as superuser

---

## Phase 1: Repo + app surface (no DB redesign yet) [DONE]

- [x] [P1-T1][ecto] Fix `with_tenant/2` post-fun clear + process-dict on failure (B1, W5) — clear outside nested TX after return (Sandbox); process dict in `after`; no clear after fun inside aborted TX
  **Locations**: `lib/elx_mcp/repo.ex`
  **Pattern**:
  ```elixir
  # Outer depth==0:
  case transaction(fn ->
         Process.put(@project_key, project_id)
         set_tenant_guc!(project_id)
         fun.()   # do NOT clear_tenant_guc! here after fun
       end) do
    {:ok, result} ->
      # LOCAL already cleared by COMMIT; process dict cleared in after
      result
    {:error, reason} ->
      {:error, reason}
  end
  # after (depth restore + Process.delete @project_key when depth was 0)
  ```
  - Rely on SET LOCAL ending with TX; optional success-only clear is redundant.
  - Nested different-tenant path: keep re-set/restore; ensure process key restored in `after` even on raise.
  - Keep `set_tenant_guc!` setting `app.project_id` LOCAL; after B2, drop `bypass_rls` lines from set/clear helpers.

- [x] [P1-T2][ecto] Add `after_connect` GUC hygiene (W2) — `Repo.after_connect/1` + `runtime.exs` wiring

- [x] [P1-T3][direct] Harden unscoped mutator docs/API (W3) — `@doc false` on `increment_time_spent`; SECDEF/admin notes on Auth/Tenancy

- [x] [P1-T4][direct] Attachment path + list limit clamps (W4, W9) — server-side `storage_path`; `list_comments` min/max clamp

- [x] [P1-T5][direct] Auth/tenancy struct load + missing project (W6, W8 + empty scopes) — `Repo.load` with UUID dump; empty scopes rejected; missing project → unauthorized

---

## Phase 2: RLS redesign migration [DONE]

Depends on P0-T1 result.

- [x] [P2-T1][ecto][security] New migration: drop policy bypass GUC; SECDEF ownership + grants (B2, B3, W1, W7) — `20260802171043_rls_bypassrls_owner.exs` + manual SQL; grants via `SET LOCAL ROLE` after ownership transfer
- [x] [P2-T2][security] Apply migration on hermes + CI and smoke-check — role + migrate applied; ACLs: EXECUTE only elx_mcp_dev (no PUBLIC); no bypass in policies; SECDEF owner `elx_mcp_secdef`

---

## Phase 3: Tests [DONE]

- [x] [P3-T1][test] Nested `with_tenant` + SECDEF-in-TX + optional WITH CHECK expand (B4, B3 regression, W14)
- [x] [P3-T2][test] Collab boundaries + worklog rollback + attachment isolation (B5, W12, W13)
- [x] [P3-T3][test] Search rank/escape + `ensure_entity_in_project` unit cases (W10, W11) — ILIKE ESCAPE in search SQL

---

## Phase 4: Verification [DONE]

- [x] [P4-T1][direct] Full verification — `mix compile --warnings-as-errors`, format, `mix test` **94 passed**
- [x] [P4-T2][direct] Update `spec/DB_SEC.md` history (v1.10) + residual notes for grants/BYPASSRLS

---

## Task Agent Annotations

| Annotation | Use |
|------------|-----|
| `[ecto]` | Repo, migrations, queries |
| `[security]` | RLS ownership, grants, auth |
| `[test]` | Test coverage tasks |
| `[direct]` | Docs, casts, clamps, verification |

## Files to Follow as Patterns

- `lib/elx_mcp/repo.ex` — current nested depth / GUC pattern
- `priv/repo/migrations/20260802170100_secdef_row_security_off.exs` — policy loop + function list
- `test/elx_mcp/rls_test.exs` — isolation / WITH CHECK / cold verify style
- `test/elx_mcp/collaboration_test.exs` — comment forbidden + foreign-entity style
- `spec/DB_SEC.md` §13.3 — operational RLS table

## Patterns to Follow

- Tenant writes: `Repo.with_tenant` + `Auth.authorize_write` + pin `project_id` via `put_change`
- SECDEF only for pre-tenant bootstrap (API key lookup, project by key, list projects)
- Parameterized SQL only (`$n` / `^`)
- RLS tests: `async: false`

## Session Handoff

- **Discovery**: Review verdict REQUIRES CHANGES; triage approved all 19 findings; approach “just fix” with BYPASSRLS owner preferred over GUC hatch.
- **Decisions**: See Technical Decisions table; `increment_time_spent` stays unscoped but `@doc false`.
- **Warnings**: Migration may need superuser on hermes for CREATE ROLE / BYPASSRLS; CI Postgres service may need role bootstrap in workflow or migration fallback; do not leave EXECUTE TO PUBLIC; after B2, search for residual `app.bypass_rls` in app code and kill it.
- **Prior verify**: 78 tests green before this plan; re-run full suite after changes.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Cannot CREATE ROLE on hermes | Manual DDL + migration grants only; document in DB_SEC |
| CI Postgres lacks BYPASSRLS role | Create in CI service init / migration with conditional |
| Dropping bypass breaks auth mid-deploy | Single migration recreates policies + functions atomically |
| `Repo.load` type mismatches from Postgrex | Normalize UUID/timestamp before load (existing cast helpers) |
| Tests flaky under Sandbox + SET LOCAL | Keep `async: false` on RLS; prefer LOCAL only |

## Verification Checklist

- [x] `mix compile --warnings-as-errors` passes
- [x] `mix format --check-formatted` passes
- [x] `mix test` passes (include rls, auth, collab, projects search) — **94 passed**
- [x] No `app.bypass_rls` in active policies (query `pg_policies`)
- [x] `\df+ elx_mcp_*` EXECUTE not PUBLIC — only `elx_mcp_dev` + owner
- [x] `spec/DB_SEC.md` matches implementation

## Finding coverage checklist (must stay 100%)

- [x] B1 → P1-T1  
- [x] B2 → P2-T1  
- [x] B3 → P2-T1 + P3-T1  
- [x] B4 → P3-T1  
- [x] B5 → P3-T2  
- [x] W1–W14 → mapped above  
