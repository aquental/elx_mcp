# Consolidated Summary

**Strategy**: Compress  
**Input**: 5 files, ~12k tokens  
**Output**: ~2.5k tokens (~80% reduction)  
**Date**: 2026-08-02

## Health Scores

| Category | Score | Weight | Weighted |
|----------|------:|-------:|---------:|
| Architecture | 71 | 0.20 | 14.20 |
| Performance | 77 | 0.25 | 19.25 |
| Security | 88 | 0.25 | 22.00 |
| Tests | 77 | 0.15 | 11.55 |
| Dependencies | 85 | 0.15 | 12.75 |
| **Overall** | | | **79.75** |

**Grade: B** (80 threshold for B; rounded overall ≈ 80)

---

## Critical Findings (P1 only)

### Architecture (3)

1. **Collaboration → Projects schema leak** — `collaboration.ex` queries `Epic`/`UserStory`/`Ticket` via `Repo` and `update_all`s `Ticket.time_spent_seconds` instead of calling `Projects` API. `increment_time_spent/3` exists, **zero callers**.
2. **Worklog `belongs_to Ticket`** — `collaboration/worklog.ex` compile-couples Collaboration → Projects (Ticket omits reverse `has_many` to avoid compile cycle).
3. **Auth duplicates Tenancy project load** — `auth.ex` rebuilds `%Tenancy.Project{}` via same SECURITY DEFINER SQL as `Tenancy.get_project/1`.

### Performance (3)

1. **Double `with_tenant` every MCP tool** — `Helpers.with_scope` + domain `tenant/2` re-runs GUC `set_config`; nested transactions create savepoints (`helpers.ex`, `projects.ex`, `collaboration.ex`, `repo.ex`).
2. **`search_work_items` ≤9 sequential RTTs** — 3 stages × 3 tables; 3× over-fetch; type-order merge starves tickets (`projects.ex:408-568`).
3. **Title ILIKE residual / unindexed description** — trgm depends on superuser `CREATE EXTENSION`; `include_description` has no GIN; key `ILIKE` may skip btree (`projects.ex` + trgm migration).

### Security

*None in app code.* Residual risk is P2+ (GUC bypass, key lifetime, infra from DB_SEC).

### Tests

*No formal P1 labels.* Highest product risk: MCP tools **not_found/unauthorized** matrix thin; collab write-auth matrix incomplete.

### Dependencies

*None* (hex.audit clean; no retired/advisory packages).

---

## Cross-Category Correlations

| Theme | Agents | Linkage |
|-------|--------|---------|
| **Context boundary + dead API + tests** | arch, test | `increment_time_spent` unused; collab reimplements write; worklog errors/auth matrix under-tested |
| **Double tenant GUC** | perf, sec (P3 nested GUC) | Nested `with_tenant` costs RTTs; different-tenant nested call can leave wrong GUC |
| **Orphan Component surface** | arch, test | Schema/RLS/migrations without list/link API; `create_component` untested |
| **God `Projects` hub** | arch, perf, test | 711 LOC / 17 fan-in; search/status multi-query; weak tool assertions on list/get |
| **SessionBind legacy 2-tuples** | perf (P2), sec (P3) | Never expire; foldl prune O(n) on bind path |
| **Auth touch_last_used** | perf (P2), test | Sync hot-path write; debounce untested |
| **CI security tooling gap** | sec, deps | No sobelow; no `mix_audit`/`deps.audit` — only `hex.audit` in precommit |
| **DB credential = full dump** | sec + DB_SEC | GUC RLS + secdef PUBLIC EXECUTE; ops C1–C3 open dominate breach model |
| **Existence full-row loads** | arch (boundary), perf (P3) | `exists_in_project?` / `ensure_same_project` load full schemas |

---

## Deduplicated Multi-Agent Findings

| Finding | Found by | Severity (max) |
|---------|----------|----------------|
| SessionBind legacy 2-tuple never expires | perf, security | P2/P3 |
| Nested `with_tenant` GUC behavior | perf (cost), security (overwrite) | P1/P3 |
| `increment_time_spent` unused / collab side-writes Ticket | arch, test | P1 |
| Component / ComponentLink incomplete | arch, test | P2 |
| Missing automated security/deps CI (sobelow, mix_audit) | security, deps | P2/P3 |
| RateLimit single-node ETS | perf (doc), security (P2) | P2 |
| Full-row existence checks | perf, (arch collab path) | P3 |
| `touch_last_used` on request path | perf, test (gap) | P2 |

---

## Non-Critical Highlights (compressed)

**Architecture P2–P3:** God `Projects` (split Boards/Sprints/WorkItems/Search); rename `Projects` vs `Tenancy.Project`; Epic↔Story↔Ticket runtime assoc cycle; compile DAG clean.

**Performance P2–P3:** `status_summary` 7 RTTs; SELECT * list/get; no cursor pagination; missing collab/sprint composite indexes; parent-cycle O(depth); issue_key `FOR UPDATE` serialize.

**Security P2:** GUC `app.bypass_rls` client-settable; no API key `expires_at`; RL IP-only; prod `DB_SSL=false` allowed; attachment cast `storage_path`; secdef EXECUTE to PUBLIC. **Ops (DB_SEC open):** public Postgres, weak password, excess privileges, git-history secrets.

**Tests:** 78 cases / 16 modules; no sleep/Mox; gaps in tools not_found, collab writes, Catalog, CORS, SessionBind TTL; cover not measured.

**Deps P2–P3:** add mix_audit; LGPL Anubis Combined Work texts incomplete; unused swoosh+req; loose `postgrex >= 0.0.0`; daisyUI vs Agents.md policy.

---

## Top Remediation Order

1. **P1 arch:** Collab entity checks + time rollup via scoped Projects API; Auth → `Tenancy.get_project/1`.
2. **P1 perf:** Single outer tenant / skip nested GUC; search `UNION ALL` + budget; trgm/description index hygiene.
3. **Ops sec:** Close DB_SEC C1–C3; document GUC-bypass = full credential trust.
4. **Tests:** MCP not_found + unauth matrix; collab write forbidden/foreign; create_component.
5. **CI:** sobelow + mix_audit in precommit.
6. **P2 product:** key `expires_at`; split Projects; ComponentLink API or drop.

---

## Coverage

| File | Represented | Key Items |
|------|:-----------:|----------:|
| arch-review.md | Yes | Score 71; 3× P1 boundaries; god context |
| perf-audit.md | Yes | Score 77; 3× P1 RTT/GUC/search |
| security-audit.md | Yes | Score 88; 0 P1 app; P2 GUC/keys/ops |
| test-audit.md | Yes | Score 77; tool/collab gaps |
| deps-audit.md | Yes | Score 85; no P1; mix_audit missing |

## Coverage Gaps

None.
