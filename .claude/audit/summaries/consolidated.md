# Audit consolidated summary — 2026-08-02 (post P1 residual)

**Overall: 82/100 (B)** — weighted  
Previous re-audit (pre residual work): **76/C**. Trend: **+6 → B**.

| Category | Score | Weight | Weighted |
|----------|------:|-------:|---------:|
| Architecture | 76 | 0.20 | 15.2 |
| Performance | 80 | 0.25 | 20.0 |
| Security | 89 | 0.25 | 22.25 |
| Test quality | 76 | 0.15 | 11.4 |
| Dependencies | 85 | 0.15 | 12.75 |
| **Overall** | **82** | | **81.6 → 82** |

## Critical / P1

**None blocking tenant data isolation or rate-limit lifetime.** Prior P1s (ETS ownership, session bind, Scope writes, search, preloads, get_*_id, resource/429 tests) are closed.

Architecture still flags **structural P1-style debt** (not security P1):

- `Projects` god context (~655 LOC, multi-aggregate)
- Collaboration queries Projects schemas directly (boundary leak)

## Cross-category correlations

1. **Security↑ + Perf↑** — session bind + Application ETS + search/preload caps landed in same residual wave.
2. **Arch vs size** — security/write patterns improved inside bloated `Projects`; split still deferred.
3. **Tests vs tools** — more MCP tests, still weak `not_found` depth and untested create paths.

## Deduplicated top residuals (P2)

| Area | Finding |
|------|---------|
| Security | API key `expires_at`; IP-only rate limit; proxy remote IP; optional SSL verify_none; attachment `storage_path` cast |
| Performance | Search ≤9 queries; `status_summary` multi-RTT; collab composite indexes; full-row encode |
| Architecture | Split Projects; collab→projects boundary; orphan Component surface |
| Tests | Tool not_found matrix; collab write auth beyond comment; SessionBind TTL test |
| Deps | No `mix_audit`; swoosh/req unused; LGPL NOTICE completeness |

## Reports

- `reports/arch-review.md` (76)
- `reports/perf-audit.md` (80)
- `reports/security-audit.md` (89)
- `reports/test-audit.md` (76)
- `reports/deps-audit.md` (85)
