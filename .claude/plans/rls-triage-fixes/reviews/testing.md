# Test Review: RLS triage fixes (P3-T1/T2/T3)

## Summary

New/changed tests in `rls_test`, `auth_test`, `collaboration_test`, and `projects_test` cover the plan-required cases: nested `with_tenant`, B1 constraint path, collab forbidden/foreign, worklog orphan, attachment isolation, search escape/rank smoke, and `ensure_entity_in_project` cases. Iron-law basics look solid (`async: false` for RLS, no `Process.sleep`, Sandbox DataCase).

**Gaps**: SECDEF-in-TX isolation soft-passes when `elx_mcp_secdef` is missing (silent green), W8 missing-project auth path untested, rank order only partially asserted, list limit clamps (W9) untested.

## Iron Law Violations

None hard-violated.

- `test/elx_mcp/rls_test.exs:2` correctly uses `async: false` for shared RLS/GUC state.
- Other three modules use `async: true` with DataCase Sandbox — acceptable.
- No `Process.sleep`, no internal DB mocks, no Mox/`verify_on_exit` issues.

## Coverage map (plan-required cases)

| Required case | Status | Where |
|---------------|--------|--------|
| Nested `with_tenant` same project | Covered | `rls_test.exs:119-132` |
| Nested `with_tenant` different projects | Covered | `rls_test.exs:134-152` |
| SECDEF-in-TX isolation (B3) | Soft-gated | `rls_test.exs:154-170` |
| Constraint B1 (`{:error, changeset}` + hygiene) | Covered | `rls_test.exs:172-180` |
| Collab forbidden (`project:write`) | Covered | `collaboration_test.exs:125-160` |
| Collab foreign entity | Covered | `collaboration_test.exs:162-227` |
| Worklog orphan / no time bump (W12) | Covered | `collaboration_test.exs:229-255` |
| Attachment isolation (W13) + path (W4) | Covered | `collaboration_test.exs:72-123` |
| Search escape `%`/`_` (W10) | Covered | `projects_test.exs:146-166` |
| Search rank order (W10) | Partial | `projects_test.exs:126-144` |
| `ensure_entity_in_project` cases (W11) | Covered | `projects_test.exs:184-216` |

## Issues Found

### Critical

_None — suite green; no removed coverage without replacement; new public boundaries under review have tests._

### Warnings

- [ ] **WARNING** `test/elx_mcp/rls_test.exs:154-170` — SECDEF-in-TX isolation soft-gates: when `elx_mcp_secdef`+`BYPASSRLS` is absent, the test body is skipped with bare `:ok` and still **passes**. CI/local without the role never exercises B3. Prefer `@tag :requires_secdef` + explicit skip message, or `flunk/1` when the role is required for the suite (post-migration CI). At minimum assert/log that the branch ran so green ≠ “skipped security regression”.

- [ ] **WARNING** `test/elx_mcp/auth_test.exs` — W8 “missing project after key lookup → unauthorized” has **zero** coverage. Doc in `Auth.verify_api_key/2` claims the behavior; add a test that inserts/looks up a key whose `project_id` no longer resolves (or mock path via SECDEF row without project) and asserts `{:error, :unauthorized}`.

- [ ] **WARNING** `test/elx_mcp/projects_test.exs:126-144` — Rank test name claims “exact before prefix before title” but only asserts `hd(keys) == epic_exact.key` for the exact query. Prefix path only checks `Enum.any?`; does not assert relative order of prefix-hit vs title-only hit. Strengthen with two distinct keys and assert index order.

- [ ] **WARNING** `test/elx_mcp/rls_test.exs:172-180` — B1 covered for `Repo.rollback(changeset)` on unique key, not for **raised** SQL abort (e.g. WITH CHECK / raw error) followed by hygiene asserts in the same test. WITH CHECK cases (`:69-85`, `:182-203`) use `assert_raise` but do not assert post-raise GUC/process hygiene. Add a raise-inside-`with_tenant` then `SELECT count(*) FROM boards == 0` (and optionally process-dict absence) case.

- [ ] **WARNING** Collab list limit clamp (W9) untested — `list_comments` / `list_changelog` clamp `limit` to `1..200` with no test for `limit: 0`, negative, or `>200`.

### Suggestions

- [ ] **SUGGESTION** `test/elx_mcp/rls_test.exs:167-168` — Else-branch comment still says “SECDEF still uses policy GUC hatch (expected B3 until migrate)”. Post-B2 that model is removed; update comment so future readers do not think the hatch remains valid.

- [ ] **SUGGESTION** `test/elx_mcp/collaboration_test.exs` — Add `record_changelog` foreign-entity rejection for symmetry with comment/attachment/worklog (same `ensure_entity` gate).

- [ ] **SUGGESTION** `test/elx_mcp/projects_test.exs:184-216` — Split `ensure_entity_in_project` into `describe` blocks (happy / nil / unknown / missing / cross-tenant) for clearer failures.

- [ ] **SUGGESTION** `test/elx_mcp/collaboration_test.exs:72-123` — Attachment isolation uses raw SQL count under other tenant; if a public `list_attachments` exists later, assert via that API too.

- [ ] **SUGGESTION** `test/elx_mcp/rls_test.exs:119-128` — Nested same-project path mostly exercises skip-GUC branch via `Projects.list_boards` nesting; consider one raw SQL count inside both depths to prove GUC remains set without relying only on context helpers.

## Verdict

**PASS WITH WARNINGS** — Plan-required cases are present and the 94-pass suite reflects real coverage for nested tenant, B1 changeset path, collab boundaries, worklog orphan, attachment isolation, search escape, and ensure_entity. Address SECDEF soft-gate visibility and W8 auth gap before treating B3/W8 as fully locked in CI.
