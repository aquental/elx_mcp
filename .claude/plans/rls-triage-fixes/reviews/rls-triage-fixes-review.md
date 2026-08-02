# Review: RLS triage fixes

**Date**: 2026-08-02  
**Plan**: `.claude/plans/rls-triage-fixes/plan.md`  
**Verdict**: **PASS WITH WARNINGS**

Agents: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge, requirements-verifier.

---

## Requirements Coverage

From plan `rls-triage-fixes` (B1–B5, W1–W14, P0–P4):

| Result | Count |
|--------|------:|
| MET | 28 |
| PARTIAL | 3 |
| UNMET | 0 |
| UNCLEAR | 1 |

- **B1–B5**: all MET  
- **W12 PARTIAL**: missing-ticket gate covers collab Multi; no direct `increment_time_spent → :not_found` unit  
- **P2-T2 PARTIAL / P4-T1 UNCLEAR in verifier**: not visible from diff alone — **session evidence**: migration applied on hermes, ACLs fixed, **`mix test` 94 passed**

No UNMET → does not force REQUIRES CHANGES.

---

## Summary

| Severity | Count | Notes |
|----------|------:|-------|
| BLOCKER | 0 | Elixir “BLOCKER” on hardcoded `elx_mcp_dev` demoted — plan W1 chose hardcode + document |
| WARNING | 7 | Privilege residual, grant portability, with_tenant edge paths, test soft-gates |
| SUGGESTION | 5 | Cast hygiene, comment tags, intermediate migration docs |

**Session verification (orchestrator)**: `mix compile --warnings-as-errors`, format, **`mix test` → 94 passed** after `elx_mcp_secdef` bootstrap + migrate + EXECUTE grants.

---

## WARNINGs (actionable residuals)

### 1. App role membership of `elx_mcp_secdef` (security)

**Where**: `priv/repo/manual/create_elx_mcp_secdef_role.sql`, migration GRANT membership  

**Issue**: `GRANT elx_mcp_secdef TO elx_mcp_dev` allows `SET ROLE elx_mcp_secdef` → BYPASSRLS + table DML on `api_keys`/`projects` without SECDEF function predicates. Needed for `ALTER OWNER` / grant fixups under NOINHERIT.

**Mitigation options**: After migrate, `REVOKE elx_mcp_secdef FROM elx_mcp_dev` if re-own is not needed at runtime; `REVOKE CREATE ON SCHEMA public FROM elx_mcp_secdef`.

### 2. Hardcoded EXECUTE grantee `elx_mcp_dev`

**Where**: `20260802171043_rls_bypassrls_owner.exs`  

**Issue**: Prod `elx_mcp_app` (if introduced) would not get EXECUTE. Plan accepted hardcode + DB_SEC docs for hermes/CI.

**Mitigation**: Grant to `CURRENT_USER` and/or env role list when prod role splits.

### 3. Migration `down/0` restores client `app.bypass_rls`

**Where**: same migration `down/0`  

**Issue**: Rollback reopens client-settable bypass. Intentional W7; **do not down on prod**.

### 4. Nested different-tenant GUC restore in `after` (elixir)

**Where**: `lib/elx_mcp/repo.ex` nested path  

**Issue**: If nested `fun` aborts the open TX, `set_tenant_guc!(prev)` in `after` can fail/mask (narrower B1 class). Rare (only cross-tenant nest).

### 5. `safe_clear_tenant_guc` not always run on re-raise

**Where**: `lib/elx_mcp/repo.ex` outer path  

**Issue**: `transaction/1` re-raises; clear runs only on `{:ok,_}` / `{:error,_}` return. Sandbox savepoint usually undoes LOCAL; wrap in `try/after` for belt-and-suspenders.

### 6. Bare `rescue _` in clear helper

**Where**: `safe_clear_tenant_guc/0`  

**Issue**: Swallows all exceptions. Narrow to DB errors only.

### 7. SECDEF isolation test soft-skips when role missing

**Where**: `test/elx_mcp/rls_test.exs`  

**Issue**: CI without bootstrap could green without B3 assert. Prefer hard fail in CI or explicit tag exclusion.

---

## SUGGESTIONs (compressed)

- Drop `:uploaded_by_email` from Attachment cast (mirror Comment author).
- Remove triage tags `(B1)`/`(W3)`/`(W4)` from durable comments (iron-law style #19).
- Document intermediate migrations: full migrate chain required; partial stops leave PUBLIC EXECUTE.
- Rank test only asserts exact-key first (prefix-before-title not fully asserted).
- W8/W9: no dedicated auth missing-project test / list limit clamp tests.

---

## Verified OK

| Area | Status |
|------|--------|
| UUID-only policies (no bypass GUC) | ✅ |
| SECDEF owner BYPASSRLS + search_path | ✅ |
| EXECUTE not PUBLIC (after grant fix) | ✅ |
| `with_tenant` outer clear + process dict | ✅ |
| `after_connect` GUC reset | ✅ |
| Server-side `storage_path` | ✅ |
| Empty scopes / missing project unauthorized | ✅ |
| Nested tenant + collab boundary tests | ✅ |
| Iron Laws (queries, atoms, money, raw) | ✅ clean |
| Full suite | ✅ 94 passed |

---

## Verdict rationale

Primary plan goals (B1–B5, B2 redesign, tests, docs) are implemented and green. Remaining items are **privilege-design residuals and portability/test hardness**, not open client bypass or failing gates. Hence **PASS WITH WARNINGS**, not REQUIRES CHANGES.

---

## Agents

| Agent | File |
|-------|------|
| elixir-reviewer | `reviews/elixir.md` |
| security-analyzer | `reviews/security.md` |
| testing-reviewer | `reviews/testing.md` |
| iron-law-judge | `reviews/iron-laws.md` |
| requirements-verifier | `reviews/requirements.md` |
