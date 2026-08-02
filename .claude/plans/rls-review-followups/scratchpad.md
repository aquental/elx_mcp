# Scratchpad: rls-review-followups

## Source

- Review: `.claude/plans/rls-triage-fixes/reviews/rls-triage-fixes-review.md`
- Parent plan: `.claude/plans/rls-triage-fixes/` (COMPLETE, 94 tests green)

## Decisions (planning)

- Parent work remains shipped-as-green; this plan is **residuals only**.
- Hardcoded `elx_mcp_dev` is WARNING not BLOCKER (parent plan W1 chose hardcode + docs).
- Prefer cheap security wins: REVOKE membership/CREATE after migrate if re-own not needed.

## Dead ends / avoid

- Re-opening `app.bypass_rls` in policies.
- Requiring Scope on `increment_time_spent` (parent decision).
- W8 DDL in `async: true` AuthTest → deadlock; keep orphan-key setup in `rls_test` (async: false).
- REVOKE membership as elx_mcp_dev on hermes → insufficient_privilege (need superuser ADMIN).

## Session notes (work complete)

- Migration 182038 applied: EXECUTE portable, CREATE revoked, membership best-effort.
- Hermes residual ops: `REVOKE elx_mcp_secdef FROM elx_mcp_dev;` as superuser.
- Suite: **98 passed**.
