# Project Health Audit — ElxMCP

**Date:** 2026-08-01  
**Mode:** Full (`/phx:audit`)  
**App:** `elx_mcp` (Phoenix 1.8 + anubis_mcp)

---

## Executive summary

| Metric | Value |
|--------|------:|
| **Overall score** | **66 / 100** |
| **Grade** | **D** (Needs Work) |
| Pulse check | Compile clean · 41 tests pass · hex.audit clean · deps current |

MVP MCP stack is coherent (contexts, dual-header auth, tenant-scoped reads). Scores pull down on **performance (unbounded/hot queries)**, **tests (coverage holes + misleading cycle test)**, and **architecture (Ticket↔Worklog cycle, dual write API)**. Security is solid on the MCP read path but needs **prod DB TLS** and stronger session/rate-limit ops.

**Weighted overall:**  
`67×0.20 + 58×0.25 + 72×0.25 + 60×0.15 + 72×0.15` = **65.7 → 66**

---

## Category scores

| Category | Score | Grade | Weight |
|----------|------:|-------|-------:|
| Architecture | 67 | D | 20% |
| Performance | **58** | F | 25% |
| Security | 72 | C | 25% |
| Test quality | 60 | D | 15% |
| Dependencies | 72 | C | 15% |

---

## Pulse check (quick)

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | Pass |
| `mix test` | **41 passed** |
| `mix hex.audit` | No retired/advisory packages |
| `mix hex.outdated` | All up-to-date |
| `mix deps.audit` | Task not installed |
| `mix xref` | 61 files · **2 cycles** · fan-out: `mcp/server.ex` (17), `projects.ex` (9) |

---

## Critical / high findings

1. **Security — `DB_SSL` defaults to `verify_none`**  
   Risk of MITM on DB traffic if prod inherits default. Force verified TLS in production.

2. **Architecture — compile cycle `Ticket` ↔ `Worklog`**  
   Schema association + `Collaboration` updates tickets via Repo. Softens context boundaries.

3. **Performance — unbounded / expensive reads**  
   Domain list APIs without default limit; `search_work_items` leading-wildcard ILIKE ×3; `status_summary` multi-round-trip + in-memory sort; heavy preloads for ID-only resolves.

4. **Tests — false cycle coverage**  
   “Detects parent ticket cycle” never asserts `{:error, :cycle_detected}`.

5. **Dependencies — `anubis_mcp` LGPL-3.0**  
   Core path; need LICENSE/NOTICE and compliance path for combined works.

6. **Security ops — MCP sessions not bound to `api_key_id`; IP-only ETS rate limit**  
   Weaker multi-node / session-hijack posture.

---

## Cross-category correlations

| Theme | Areas |
|-------|--------|
| Unbounded lists | Performance + Tests (missing limit assertions) + future Security (DoS) |
| Scope dual API (read Scope / write project_id) | Architecture + Security (latent IDOR when write tools ship) |
| Cycle Ticket/Worklog | Architecture + Performance (preload graphs) |
| Thin MCP resource/tool tests | Tests + Security confidence on isolation |

---

## Top recommendations

### Immediate
1. Set **`DB_SSL=true`** (or verified SSL) in production runtime; never ship `verify_none` as prod default.  
2. Cap domain `list_*` defaults; thin `get_*` preloads used only for ID resolution.  
3. Fix cycle test to assert `{:error, :cycle_detected}` (or remove the false claim).

### Short-term
4. Bind Anubis sessions to `api_key_id` / tenant; harden rate limit (atomic, multi-node-ready).  
5. Scope-first mutations; stop casting `project_id` from client attrs.  
6. Break Ticket↔Worklog cycle (drop reverse assoc or move aggregate update behind Projects API).  
7. Expand MCP tool/resource tests; add authenticated `/mcp` E2E smoke.  
8. Document LGPL for Anubis; add `mix_audit` / hex audit to CI; align Elixir `~> 1.18` if Anubis requires it.

### Long-term
9. Split `Projects` context or extract boards/sprints.  
10. Search via `pg_trgm` / FTS instead of leading `%ILIKE`.  
11. Component/changelog write paths or remove dead surface.

---

## What’s healthy

- Dual-header auth (`X-API-Key` + `X-Email`) with hash-at-rest keys  
- MCP reads filter by `project_id` from Scope  
- Compile clean, suite green, Hex packages current  
- Thin web layer (plugs + MCP, no bloated LiveView domain yet)  
- Clear folder layout: Tenancy / Projects / Collaboration / Auth / MCP  

---

## Artifact index

| File | Content |
|------|---------|
| [arch-review.md](../reports/arch-review.md) | Architecture |
| [perf-audit.md](../reports/perf-audit.md) | Performance |
| [security-audit.md](../reports/security-audit.md) | Security |
| [test-audit.md](../reports/test-audit.md) | Tests |
| [deps-audit.md](../reports/deps-audit.md) | Dependencies |
| [consolidated.md](consolidated.md) | Compressed summary |

---

## Next steps

- `/phx:plan` from this audit for a fix backlog  
- `/phx:review` after each PR  
- Re-run `/phx:audit` after performance + TLS + test fixes to track score trend (**do not** compare scores across different projects)
