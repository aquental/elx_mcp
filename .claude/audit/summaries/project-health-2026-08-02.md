# Project Health Audit — ElxMCP

**Date:** 2026-08-02  
**Mode:** Full `/phx:audit`  
**Commit:** `1e92210` (Apply audit remediation) + local uncommitted MCP/config/audit noise  
**Compared to:** Same-day prior re-audit overall **78 (C)**; original baseline 2026-08-01 **66 (D)**

---

## Executive summary

| Metric | 2026-08-01 | Prior 08-02 | **This audit** |
|--------|----------:|------------:|---------------:|
| **Overall score** | 66 | 78 | **76** |
| **Grade** | D | C | **C** (Needs Attention) |
| Pulse | — | 45 tests | **45 passed** · compile clean · hex.audit clean · 2 runtime xref cycles |

Remediation (dual-header auth, list limits, indexes, Worklog cycle break, prod SSL default, NOTICE) still holds. This pass **re-scored more strictly** on rate-limit ETS ownership (security P1), session binding, ILIKE/preloads, and missing CVE tooling — overall **−2** vs earlier 78, not a regression in shipped code.

**Weighted:**  
`74×0.20 + 72×0.25 + 80×0.25 + 72×0.15 + 85×0.15` = **76.35 → 76**

---

## Category scores

| Category | 08-01 | Prior 08-02 | **Now** | Δ | Grade |
|----------|------:|------------:|--------:|--:|-------|
| Architecture | 67 | 74 | **74** | 0 | C |
| Performance | 58 | 74 | **72** | −2 | C |
| Security | 72 | 83 | **80** | −3 | B |
| Test quality | 60 | 72 | **72** | 0 | C |
| Dependencies | 72 | 86 | **85** | −1 | B |

---

## Pulse check

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | Pass |
| `mix test` | **45 passed** (~50s) |
| `mix hex.audit` | No retired/advisories |
| `mix hex.outdated` | All top-level Hex deps up-to-date |
| `mix xref cycles` | **2 runtime** (Phoenix web; Epic↔Story↔Ticket). **0 compile** |
| `mix deps.audit` / sobelow | Not installed |

---

## Top issues (P1, deduped)

1. **Rate-limit ETS owned by request process** — table deleted when creator exits; counters do not accumulate across connections → abuse protection largely ineffective in prod. Cross: security + perf + test flake risk.
2. **MCP sessions not bound to `api_key_id` / project** — SSE/DELETE by session id only; tool data still re-authed and tenant-scoped.
3. **Dual Scope API** — writes take bare `project_id`; `project:write` never enforced (latent until write tools land).
4. **Search** — leading-`%` ILIKE × 3 tables; no FTS/trgm.
5. **Unbounded `get_*` preloads** + comments/changelog resolving via full `get_*` for id only.
6. **Tests** — 4/5 MCP resources untested; tools mostly `isError` smoke; Plug 429 not integration-tested.

---

## Cross-category correlations

| Root cause | Categories |
|------------|------------|
| ETS rate-limit ownership / GC / single-node | Security, Performance, Tests |
| Dual Scope + cast `:project_id` + unused `project:write` | Architecture, Security |
| Unbounded get preloads + full encode | Performance, Tests |
| No `mix_audit` / sobelow in CI | Dependencies, Security |

---

## What’s healthy

- Dual-header auth (X-API-Key + X-Email), SHA-256 keys, email `secure_compare`
- All MCP tools/resources resolve `%Scope{}` and pin `project_id` on reads
- No `String.to_atom` / `raw` / interpolated SQL
- List defaults 50 / max 200; list indexes present; Ticket↔Worklog cycle fixed
- Prod `DB_SSL` default true; secrets via env; `.env` gitignored
- Hex audit clean; deps current; Anubis LGPL noted in NOTICE

---

## Action plan

### Immediate
1. Own rate-limit ETS from `Application` (+ prune); verify across two TCP connections  
2. Bind MCP sessions to key/project (or document risk acceptance)  
3. Wire comments/changelog to `get_*_id` (+ `get_ticket_id`)  
4. Add `mix_audit` + `sobelow` (or accept risk)  
5. Resource tests + MCPAuth 429 integration test after ETS fix  

### Short-term
6. Scope-first mutations; stop casting `project_id`; enforce `project:write` before any write tools  
7. Search: key exact/prefix + trgm/FTS  
8. Cap/paginate `get_*` children; list projections  
9. API key `expires_at`; deeper tool JSON asserts; factories  

### Long-term
10. Split `Projects` multi-aggregate; cursor pagination; multi-node rate limit  
11. Drop unused swoosh/req or productize; LGPL binary pack if shipping releases  

---

## Artifacts

| File |
|------|
| [arch-review.md](../reports/arch-review.md) |
| [perf-audit.md](../reports/perf-audit.md) |
| [security-audit.md](../reports/security-audit.md) |
| [test-audit.md](../reports/test-audit.md) |
| [deps-audit.md](../reports/deps-audit.md) |
| [consolidated.md](consolidated.md) |
| [project-health-2026-08-01.md](project-health-2026-08-01.md) (baseline) |

**Do not compare scores across different projects** — only track trend on ElxMCP.
