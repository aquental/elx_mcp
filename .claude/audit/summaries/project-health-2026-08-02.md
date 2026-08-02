# Project Health — ElxMCP — 2026-08-02

**Overall score: 82/100 — Grade B**  
**Suite:** 71 tests green · `mix compile --warnings-as-errors`  
**Context:** Post `/phx:work` on `.claude/plans/elx-mcp-p1-residual/` (commit `c6e3358` + solutions)

## Executive summary

ElxMCP moved from **76/C → 82/B** after closing the seven residual P1s: Application-owned rate-limit ETS, Path A MCP session binding, Scope-first `project:write` mutations, search fast paths + `pg_trgm`, capped get_* preloads, ID-only resolves for comments/changelog, and deeper MCP resource/429 tests.

No open **security P1** for tenant isolation or rate-limit table lifetime. Remaining work is structural debt, performance polish, key expiry, and test depth.

## Category scores

| Category | Score | Grade | Notes |
|----------|------:|:-----:|-------|
| Architecture | 76 | C | Scope writes fixed; Projects still multi-aggregate |
| Performance | 80 | B | Search/preload P1s fixed; multi-query search residual |
| Security | 89 | B+ | Session bind + authorize_write solid; key expiry P2 |
| Test quality | 76 | C | 71 tests; tools not_found matrix still thin |
| Dependencies | 85 | B | hex.audit clean; no mix_audit; unused swoosh/req |

**Weighted overall** = 0.20×76 + 0.25×80 + 0.25×89 + 0.15×76 + 0.15×85 ≈ **82 (B)**

## Critical issues

_None at CRITICAL override level (failing suite, hardcoded secrets, open data IDOR)._

## Top recommendations

### Immediate (optional polish)

1. Tool `not_found` coverage for get_* resources already partially covered; extend list tools.
2. SessionBind TTL unit test + drop legacy 2-tuple support after one release.
3. Cap attachment mass-assign: stop casting `storage_path` / force uploader from Scope (partially done for email).

### Short-term (P2)

1. API key `expires_at` + reject expired in `verify_api_key`.
2. Trusted proxy / post-auth rate-limit key for multi-tenant prod.
3. Split `Projects` into boards/sprints vs issues contexts (arch debt).
4. Collab composite indexes `(project_id, commentable_type, commentable_id)`.
5. Install `mix_audit` / sobelow for CI hygiene.

### Long-term

1. Multi-node rate limit + session bind (Redis/Hammer).
2. Cursor pagination for large lists.
3. Drop or wire unused `swoosh`/`req` / Component surface.

## Action plan

| Horizon | Actions |
|---------|---------|
| Now | Ship B-grade baseline; optional compound already written |
| This sprint | Key expiry, tool not_found tests, collab indexes |
| Next quarter | Context split, multi-node limiters, sobelow+mix_audit |

## Trend

| Date | Overall | Notes |
|------|--------:|-------|
| 2026-08-01 | ~first remediation | Auth email, cycle, hygiene |
| 2026-08-02 pre-residual | **76/C** | Seven P1 residuals |
| 2026-08-02 post-residual | **82/B** | This audit |

## Compounded knowledge (this wave)

- `.claude/solutions/otp-issues/rate-limit-ets-owned-by-request-process-20260802.md`
- `.claude/solutions/security-issues/mcp-session-bind-path-a-20260802.md`
- `.claude/solutions/security-issues/scope-first-writes-project-write-20260802.md`
