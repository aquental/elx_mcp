# Plan: RLS review follow-ups

**Status**: COMPLETE  
**Created**: 2026-08-02  
**Detail Level**: standard  
**Input**: `.claude/plans/rls-triage-fixes/reviews/rls-triage-fixes-review.md`  
**Parent**: `.claude/plans/rls-triage-fixes/` (COMPLETE)

## Summary

Close residual WARNINGs and cheap SUGGESTIONs from the RLS triage review without reopening the RLS redesign. Priorities: shrink blast radius of `elx_mcp_secdef` membership, harden `with_tenant` edge paths, make B3 tests hard-fail in CI when role is expected, and polish docs/casts/tests.

## Scope

**In Scope:**

- All review WARNINGs (7)
- Cheap SUGGESTIONs that fit while touching the same files
- Optional EXECUTE grantee portability (CURRENT_USER / env)
- Docs for `down/0` prod hazard

**Out of Scope:**

- LiveView / MCP write tools
- Full RLS matrix expansion beyond parent W14
- Production secret manager migration
- Replacing SECDEF bootstrap model

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Secdef membership | **Revoke** `elx_mcp_secdef` from app role after ownership+grants in a small follow-up migration (or document one-shot ops SQL) | Runtime SET ROLE bypass residual; re-own rare |
| Schema CREATE | **Revoke CREATE** on `public` from secdef after ownership | Least privilege |
| App EXECUTE role | Grant to **CURRENT_USER** at migrate + keep `elx_mcp_dev` if different | Portability without full role matrix |
| Nested GUC restore | Wrap nested restore in **safe** set (rescue DB errors only) | Same class as B1, narrow surface |
| Outer clear on raise | `try/after` around `transaction/1` so clear always attempts at depth 0 | Sandbox + real TX |
| SECDEF test gate | **Assert role present** in CI/test when `ELX_MCP_REQUIRE_SECDEF=1` or always flunk with clear message if policies UUID-only but role missing | Prevent silent B3 skip |
| Migration down | Document “never down in prod”; no code change required unless irreversible preferred | W7 intentional |

## Completeness (review → plan map)

| Finding | Task(s) |
|---------|---------|
| W: secdef membership SET ROLE | P1-T1 |
| W: hardcoded EXECUTE role | P1-T2 |
| W: down restores bypass | P1-T3 |
| W: nested GUC restore after abort | P1-T4 |
| W: clear skipped on re-raise | P1-T4 |
| W: bare rescue clear | P1-T4 |
| W: SECDEF test soft-skip | P2-T1 |
| S: uploaded_by_email cast | P1-T5 |
| S: triage tags in comments | P1-T5 |
| S: intermediate migrate docs | P1-T3 |
| S: rank/prefix/title test | P2-T2 |
| S: W8/W9 missing tests | P2-T2 |
| W12 PARTIAL (increment not_found) | P2-T2 |
| Permanent CREATE on public | P1-T1 |

---

## Phase 1: Security + Repo hygiene [COMPLETE]

- [x] [P1-T1][security] Shrink secdef blast radius after ownership — migration `20260802182038_rls_secdef_least_privilege.exs` revokes CREATE; membership REVOKE best-effort (hermes needs superuser ops SQL — documented in DB_SEC + manual SQL)
- [x] [P1-T2][ecto][security] Portable EXECUTE grantee — same migration grants EXECUTE to CURRENT_USER + elx_mcp_dev if different; PUBLIC revoked
- [x] [P1-T3][direct] Ops docs for down/bypass and migrate chain — DB_SEC §13.3 v1.11; moduledoc on 171043; manual SQL lifecycle notes
- [x] [P1-T4][ecto] `with_tenant` edge-path hygiene — outer try/after clear; nested safe GUC restore; rescue narrowed to Postgrex.Error / DBConnection.ConnectionError
- [x] [P1-T5][direct] Cast + comment polish — drop uploaded_by_email from Attachment cast; strip (B1)/(W3)/(W4) triage tags

---

## Phase 2: Tests [COMPLETE]

- [x] [P2-T1][test] Harden SECDEF isolation gate — flunk when UUID-only policies + role missing unless `ELX_MCP_ALLOW_MISSING_SECDEF=1`
- [x] [P2-T2][test] Fill residual coverage gaps — W8 orphan project (rls_test async:false); W9 list limit clamps; rank exact < prefix < title; increment_time_spent :not_found

---

## Phase 3: Verification [COMPLETE]

- [x] [P3-T1][direct] Full verification — `mix compile --warnings-as-errors`, format, **mix test 98 passed**. Smoke: CREATE revoked; EXECUTE no PUBLIC; membership still true on hermes until superuser `REVOKE elx_mcp_secdef FROM elx_mcp_dev`

---

## Finding coverage checklist (must stay 100%)

- [x] Membership SET ROLE → P1-T1  
- [x] Hardcoded EXECUTE → P1-T2  
- [x] down bypass restore → P1-T3  
- [x] Nested restore / clear on raise / bare rescue → P1-T4  
- [x] SECDEF soft-skip → P2-T1  
- [x] Attachment cast / triage tags → P1-T5  
- [x] Intermediate migrate docs → P1-T3  
- [x] Rank / W8 / W9 / W12 gaps → P2-T2  
- [x] CREATE on public → P1-T1  

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| REVOKE membership breaks future re-own | Document temporary `GRANT role TO app` for ops re-own |
| flunk SECDEF breaks local without bootstrap | Opt-out env for local only; CI requires role |
| Narrow rescue misses error type | Match common Postgrex/DBConnection classes; re-raise others |
| hermes app cannot REVOKE membership | Best-effort NOTICE + superuser ops SQL in DB_SEC |

## Session Handoff

- Parent: 94 tests green; migration 171043 applied; grants fixed live.
- This plan: 98 tests green; migration 182038 applied; CREATE revoked; membership REVOKE pending superuser on hermes.
- Do not re-open bypass GUC in policies.
- Prefer new migration over rewriting 171043 on hermes.

## Verification Checklist

- [x] compile / format / full test green (98)
- [x] app not member of elx_mcp_secdef (or documented exception) — hermes residual documented
- [x] PUBLIC no EXECUTE on elx_mcp_*
- [x] SECDEF-in-TX test asserts when role present
- [x] DB_SEC notes down/prod + bootstrap
