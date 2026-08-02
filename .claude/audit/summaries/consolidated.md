# Consolidated Audit Summary — ElxMCP
**Date:** 2026-08-02  
**Overall:** 76 (C)  
**Strategy:** Compress  
**Input:** 5 files, ~12k tokens  
**Output:** ~2.5k tokens  

**Formula:** `arch×0.20 + perf×0.25 + sec×0.25 + test×0.15 + deps×0.15`  
= `74×0.20 + 72×0.25 + 80×0.25 + 72×0.15 + 85×0.15`  
= `14.8 + 18.0 + 20.0 + 10.8 + 12.75` = **76.35 → 76**

**Comparison (previous re-audit):** 78 (arch 74, perf 74, sec 83, test 72, deps 86)  
**Delta:** −2 overall (perf −2, sec −3, deps −1; arch/test flat). Residual class unchanged; stricter scoring on rate-limit/session/search/preload and CVE-audit hygiene.

---

## Category scores

| Category | Score | Grade | Weight | Weighted | Δ vs prior |
|----------|------:|-------|-------:|---------:|-----------:|
| Architecture | **74** | C | 0.20 | 14.8 | 0 |
| Performance | **72** | C | 0.25 | 18.0 | −2 |
| Security | **80** | B | 0.25 | 20.0 | −3 |
| Tests | **72** | C | 0.15 | 10.8 | 0 |
| Dependencies | **85** | B | 0.15 | 12.75 | −1 |
| **Overall** | **76** | **C** | 1.00 | **76.35** | **−2** |

---

## Critical / P1 (deduped)

### Security / Auth runtime

1. **Rate-limit ETS not Application-owned → table dies with first creator process**  
   - **Sources:** security-audit (P1 #1), perf-audit (P2 #11), test-audit (async ETS flake)  
   - `auth/rate_limit.ex` + `mcp_auth.ex`: named public ETS created by request process; exit deletes table; counters don’t accumulate across connections → abuse protection largely ineffective. Also: no bucket GC, single-node, IP-only key.  
   - **Fix:** Create/own table in Application (or GenServer + heir); prune buckets; post-auth key by `api_key_id`; multi-node → Redis/Hammer.

2. **MCP sessions not bound to `api_key_id` / project**  
   - **Source:** security-audit (P1 #2)  
   - Session lifecycle (SSE/DELETE) keyed only by client `mcp-session-id`; ~48-bit practical entropy; any authed principal who knows session id can disrupt another client. Tool data remains tenant-correct via re-auth + assigns merge.  
   - **Fix:** Bind session → `{api_key_id, project_id}`; reject lifecycle ops on mismatch; higher-entropy ids.

### Architecture / authz dual-API (latent write path)

3. **Writes take bare `project_id`; `project:write` catalogued but never enforced**  
   - **Sources:** arch-review (P1 ×3), security-audit (P2 #4/#6)  
   - Projects + Collaboration mutations use bare `project_id`; `verify_api_key` only requires `project:read`; authn fused with min authz. No MCP write tools yet, but future tools inherit IDOR/mass-assignment risk.  
   - **Fix:** `create_*(%Scope{}, attrs)`; enforce `Scope.has_scope?(scope, "project:write")` at mutation boundary; separate authn from scope checks.

### Performance (read path)

4. **Leading-`%` ILIKE search × 3 tables (no FTS/trgm)**  
   - **Source:** perf-audit (P1 #1); security notes parameterized ILIKE only (no SQLi)  
   - `projects.ex` `search_work_items/3` — B-tree unusable; three sequential scans; no ranking.  
   - **Fix:** exact/prefix key path; `pg_trgm` GIN or FTS; keep hard cap.

5. **Unbounded `has_many` preloads on `get_*` + full-graph MCP encode**  
   - **Source:** perf-audit (P1 #2)  
   - `get_epic` / `get_user_story` / `get_ticket` preload children without cap; tools/resources encode full structs.  
   - **Fix:** Cap/paginate children or split detail vs list APIs.

6. **list_comments / list_changelog resolve entity via full `get_*`**  
   - **Source:** perf-audit (P1 #3)  
   - Wastes association loads for id-only resolution.  
   - **Fix:** Use `get_*_id` (+ add `get_ticket_id`).

### Tests

7. **MCP resources mostly untested; tools smoke-only; Plug 429 missing**  
   - **Source:** test-audit (P1 ×3)  
   - 4/5 resources untested; tools assert `isError` only; 429 path not integration-tested (ties to broken rate-limit).  
   - **Fix:** Resource happy/not_found/unauth; decode JSON shape; MCPAuth 429 after ETS ownership fix.

**Deps:** no P1.

---

## Cross-category correlations

| Root cause | Agents | Impact |
|------------|--------|--------|
| **Dual Scope API + cast `:project_id` + unused `project:write`** | arch, security | Latent tenant IDOR on any future write tool; Ticket already correct (`put_change` only) |
| **Rate-limit ETS ownership / GC / single-node** | security (P1), perf (P2), test (flake/429 gap) | Ineffective prod limiting + flaky concurrent tests |
| **Unbounded get preloads + full encode** | perf (P1), test (weak get asserts) | Memory/JSON cost; weak regression signal |
| **Search ILIKE without FTS** | perf (P1), security (P3 escape only) | Tenant-scoped perf risk, not SQLi |
| **Missing CVE/static tooling** | deps (`mix_audit`), security (`sobelow` absent) | No automated advisory/static security gate in CI |
| **MCP session vs tenant binding** | security only | Orthogonal to tool tenant isolation (which is sound) |

---

## P2 residual (compressed)

| Area | Items |
|------|--------|
| **Arch** | Projects multi-aggregate hub (~433 LOC / 21 public); dead Component/ComponentLink surface; polymorphic collab writes without entity ownership; FKs still in cast lists (non-Ticket) |
| **Perf** | `status_summary` 7 sequential RTTs; list APIs limit-only (no cursor); full-schema list encode; `list_changelog` domain limit uncapped; `list_comments` no MCP limit; sync `touch_last_used`; missing collab composite indexes |
| **Sec** | API keys never expire; prod `DB_SSL=false` opt-out; no auth audit trail |
| **Test** | No ListTickets happy path; Projects filter/component gaps; CORS untested; no factories; shared ETS + async MCPAuth |
| **Deps** | No `mix_audit`/deps.audit; LGPL Combined Work packaging incomplete for binary ship; unused `swoosh`/`req`; loose `postgrex ">= 0.0.0"` |

P3 omitted (naming Projects vs Tenancy.Project, framework xref cycle, validation_matrix mega-test, etc.).

---

## Action plan

### Immediate (this sprint)

1. **Own rate-limit ETS in Application** (+ basic bucket prune); prove counters across two TCP connections.  
2. **Bind MCP sessions to `api_key_id`/`project_id`** (or document Anubis limitation + risk acceptance).  
3. **Wire comments/changelog to `get_*_id`** (+ `get_ticket_id`); stop full get for id resolve.  
4. **Add `mix_audit` + `mix sobelow`** to dev deps / precommit (or explicit risk accept).  
5. **Integration test MCPAuth 429** after ETS fix; cover remaining 4 MCP resources smoke + not_found.

### Short-term (next 1–2 sprints)

6. **Scope-first mutations** on Projects/Collaboration; drop `:project_id`/`:key` from cast; enforce `project:write` when any write tool lands.  
7. **Search path:** key exact/prefix + trgm/FTS; keep cap; optional ranking.  
8. **Cap/paginate get_* children**; list projections (`key/title/status/…`) instead of full encode.  
9. **API key `expires_at`** + rotation runbook; SQL-gate or async `last_used_at`.  
10. **Test depth:** ListTickets happy path; JSON shape asserts; CORS plug; factories for DataCase.  
11. Cap `list_changelog`; expose limit on `list_comments`; tighten `postgrex` pin.

### Long-term

12. Split Projects multi-aggregate before write surface grows.  
13. Cursor pagination + collab composite indexes; parallelize/CTE `status_summary`.  
14. Multi-node rate limit (Redis/Hammer) + trusted-proxy IP.  
15. Remove unused swoosh/req or productize email; complete LGPL Combined Work pack if shipping binaries.  
16. Full `/mcp` E2E; auth audit events; optional domain changelog on mutations.

---

## Coverage

| File | Represented | Key items |
|------|-------------|-----------|
| arch-review.md | Yes | Score 74; dual Scope; project:write; god-context; Component dead |
| perf-audit.md | Yes | Score 72; ILIKE search; unbounded preloads; get_* for lists |
| security-audit.md | Yes | Score 80; ETS ownership; session binding; cast/expiry |
| test-audit.md | Yes | Score 72; resources/tools/429 gaps |
| deps-audit.md | Yes | Score 85; no mix_audit; LGPL; unused deps |

## Coverage gaps

None.
