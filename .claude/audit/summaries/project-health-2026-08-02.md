# Project Health Audit — ElxMCP

**Date:** 2026-08-02  
**Command:** `/phx:audit` (full)  
**Pulse:** `mix compile --warnings-as-errors` ✓ · `mix test` **78 passed**  
**Overall:** **79.8 / 100** · **Grade B**

---

## Executive summary

ElxMCP is a **healthy B-grade** Phoenix MCP app: compile/tests green, no Hex advisories, strong app-layer security (API keys, SessionBind, FORCE RLS + SET LOCAL, dual-header auth). Architecture and hot-path performance drag the score: **Collaboration leaks into Projects schemas**, **double `with_tenant`** on every MCP tool, and **search fan-out** (≤9 queries). Residual **ops** risks (public Postgres, etc.) sit outside the app score but dominate real-world blast radius if unremediated (`spec/DB_SEC.md`).

---

## Category scores

| Category | Score | Grade | Weight | Weighted |
|----------|------:|:-----:|-------:|---------:|
| Architecture | 71 | C | 0.20 | 14.2 |
| Performance | 77 | C | 0.25 | 19.3 |
| Security | 88 | B | 0.25 | 22.0 |
| Tests | 77 | C | 0.15 | 11.6 |
| Dependencies | 85 | B | 0.15 | 12.8 |
| **Overall** | **79.8** | **B** | | **79.8** |

```
overall = 71×0.20 + 77×0.25 + 88×0.25 + 77×0.15 + 85×0.15 ≈ 79.8
```

---

## Critical / P1 issues (app)

| # | Area | Finding |
|---|------|---------|
| 1 | Arch | `Collaboration` queries/mutates `Projects.{Epic,Ticket,UserStory}` via Repo; **bypasses** `Projects.increment_time_spent/3` (dead API) |
| 2 | Arch | Worklog `belongs_to Ticket` couples contexts; Auth rebuilds `Tenancy.Project` instead of `Tenancy.get_project/1` |
| 3 | Perf | **Double `with_tenant`**: `Helpers.with_scope` + domain `tenant/2` → extra GUC RTT + savepoints |
| 4 | Perf | **`search_work_items`** ≤9 sequential `Repo.all`; over-fetch + type-order bias |
| 5 | Perf | Search residual indexes (description ILIKE; key ILIKE vs btree; trgm ops hygiene) |

**Security app P1:** none.  
**Deps P1:** none (`hex.audit` clean).

---

## Top recommendations

### Immediate (this week)

1. Route collab entity checks + time rollup through **Projects** API (`increment_time_spent` callers).
2. **Single outer tenant** for MCP: drop nested `tenant/2` when already under `with_scope`, or skip GUC when depth>0 without re-set.
3. Document/trust model: DB credential + GUC `app.bypass_rls` = full data access (RLS is defense-in-depth).

### Short-term (2–4 weeks)

4. Collapse **search** into fewer queries (`UNION ALL` / budget per type).
5. MCP tool test matrix: **unauthorized + not_found** per tool; collab write `:forbidden` / foreign entity.
6. CI: add **sobelow** + **mix_audit** (deps.audit) to precommit.
7. Ops: finish **DB_SEC** open items (network, `pg_hba` aquental) if not done.

### Long-term

8. Split god context **Projects** (Boards / Sprints / WorkItems / Search).
9. ComponentLink product API or remove orphan surface.
10. API key `expires_at`; multi-node rate limit if multi-instance.

---

## Cross-cutting themes

| Theme | Categories |
|-------|------------|
| Boundary leak + dead API + thin collab tests | Arch + Test |
| Double tenant GUC cost/risk | Perf + Sec (P3 nested) |
| God `Projects` hub | Arch + Perf + Test |
| No sobelow/mix_audit in CI | Sec + Deps |
| SessionBind legacy 2-tuples | Perf + Sec |

---

## Action plan

| Horizon | Actions |
|---------|---------|
| **Immediate** | Fix collab→Projects API; de-nest `with_tenant` on MCP path |
| **Short-term** | Search query collapse; tool/collab test matrix; sobelow+mix_audit CI |
| **Long-term** | Split Projects; ComponentLink API; key expiry; multi-node RL |

---

## Artifacts

| Path | Content |
|------|---------|
| `.claude/audit/reports/arch-review.md` | Architecture (71) |
| `.claude/audit/reports/perf-audit.md` | Performance (77) |
| `.claude/audit/reports/security-audit.md` | Security (88) |
| `.claude/audit/reports/test-audit.md` | Tests (77) |
| `.claude/audit/reports/deps-audit.md` | Dependencies (85) |
| `.claude/audit/summaries/consolidated.md` | Compressed multi-agent digest |
| `.claude/audit/summaries/project-health-2026-08-02.md` | This report |

---

## Pulse checks (this run)

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | Pass |
| `mix test` | **78 passed** |
| Critical override (failing tests / compile) | None |
