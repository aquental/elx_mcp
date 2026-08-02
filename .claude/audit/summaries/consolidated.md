# Consolidated Summary

**Strategy**: Compress  
**Input**: 5 files, ~9k tokens  
**Output**: ~2.5k tokens (~72% reduction)  
**Date**: 2026-08-01  

## Health scores

| Category | Score | Weight | Weighted |
|----------|------:|-------:|---------:|
| Architecture | 67 | 20% | 13.4 |
| Performance | 58 | 25% | 14.5 |
| Security | 72 | 25% | 18.0 |
| Tests | 60 | 15% | 9.0 |
| Dependencies | 72 | 15% | 10.8 |
| **Overall** | **66** | 100% | **65.7** |

**Overall: 66 / 100** — solid skeleton and auth core; performance and test gaps dominate risk under growth.

## Critical findings (deduped)

> Security reported **no app-code criticals**. Below = highest-severity / cross-cutting items only (P0–P1 / Critical / HIGH).

### Security / infra

1. **DB TLS defaults to `verify_none`** — `config/runtime.exs` (`DB_SSL`). Prod MITM risk on tenant data + `key_hash`. *Source: security-audit*
2. **MCP sessions unbound to `api_key_id` / weak session entropy** — session DELETE/SSE keyed only by low-entropy Anubis id. *Source: security-audit*
3. **Rate limiter weak** — IP-only, non-atomic ETS RMW, non-distributed, unbounded keys. *Sources: security-audit, test-audit (flake), perf-audit (touch path)*

### Architecture / security latent authz

4. **Cross-context cycle + Repo reach-in** — `Projects.Ticket` ↔ `Collaboration.Worklog`; Collaboration updates Ticket `time_spent_seconds` via direct Repo. *Source: arch-review*
5. **Scope dual API + `project:write` unused** — reads use `%Scope{}`, writes bare `project_id`; verify requires only `project:read`. *Sources: arch-review, security-audit*
6. **FK / `project_id` cast on schemas** — mass-assignment IDOR when write tools land. *Sources: arch-review, security-audit*

### Performance (P1)

7. **`status_summary/2` 7-query fan-out + 3×N full-row recent** — `projects.ex`; MCP status tool/resource. *Source: perf-audit*
8. **Unbounded domain lists** when `limit` omitted (`list_epics/stories/tickets`). *Source: perf-audit*
9. **`search_work_items` leading-`%` ILIKE ×3 tables** — no FTS/trgm; up to 3× limit before merge. *Source: perf-audit*
10. **Unbounded `get_*` has_many preloads** + **list tools resolve keys via full `get_*`**. *Source: perf-audit* (ties to arch incomplete boundaries)

### Tests (false confidence)

11. **Cycle-detection test does not fail** — `projects_test.exs` ~L107–127 asserts `{:ok,_}` only; never `{:error, :cycle_detected}`. *Source: test-audit*
12. **5/12 MCP tools + 0/5 resources untested**; rate-limit 429 untested. *Source: test-audit*

### Dependencies (HIGH)

13. **`anubis_mcp` LGPL-3.0** — Combined Work on BEAM; no LICENSE/NOTICE/redistribution docs. *Source: deps-audit*
14. **Elixir pin `~> 1.17` vs Anubis `~> 1.18`**. *Source: deps-audit*

## Cross-category correlations

| Theme | Categories | Link |
|-------|------------|------|
| **Write path not production-ready** | Arch + Sec + Tests | Incomplete mutations, FK cast, no `project:write` gate; tests don’t cover write hazards; security marks as latent IDOR |
| **Auth path cost & correctness** | Perf + Sec + Tests | Sync `touch_last_used` + non-atomic debounce (perf); rate limit non-atomic/IP-only (sec); neither 429 nor last_used tested |
| **Over-fetch = blast radius** | Perf + Arch + Sec | Full preloads on get/list resolve increase data exposure surface if session/tool bugs; soft context boundaries (worklogs on ticket) |
| **Scope / tenant boundary** | Arch + Sec + Perf | Dual Scope vs `project_id` weakens authz; list/search without hard caps amplify cross-tenant mistakes if filters ever drop |
| **MCP surface maturity** | Arch + Tests + Deps | Read-only tools thin; incomplete coverage; LGPL Anubis is core of all MCP transport |
| **Operational readiness** | Sec + Deps | TLS defaults + missing `mix_audit` in precommit leave prod/compliance gaps |

## Top 5 recommendations

1. **Prod DB TLS verify-peer** — require CA (`DB_SSL` + `DB_CA_CERT`); never default `verify_none` in prod. *(Security P0)*
2. **Cap & thin domain queries** — default/max `limit` on list/search; collapse `status_summary`; ID-only key resolve; limit preloads; add `(project_id, updated_at DESC)` (+ assignee/polymorphic composites). *(Performance P1)*
3. **Harden auth transport** — bind MCP sessions to key/tenant; atomic multi-node rate limit (+ proxy trust); optional key `expires_at`. *(Security P1)*
4. **Close context boundaries before writes** — break Ticket↔Worklog cycle; Scope-first mutations; stop casting tenant FKs; enforce `project:write` on every mutation. *(Architecture + Security latent)*
5. **Fix false tests + LGPL/compliance** — real cycle-detection assertion; cover remaining tools/resources + 429; document Anubis LGPL NOTICE + raise Elixir to `~> 1.18`; add `mix_audit` to precommit. *(Tests + Dependencies)*

## Coverage

| File | Represented | Key items |
|------|:-----------:|----------:|
| arch-review.md | Yes | 6 (cycle, Repo, scope, write scope, FK cast, incomplete surface) |
| perf-audit.md | Yes | 5 P1 + index gaps |
| security-audit.md | Yes | DB TLS, sessions, rate limit, key expiry, FK cast |
| test-audit.md | Yes | Cycle false test, tool/resource gaps, 429, ETS flake |
| deps-audit.md | Yes | LGPL, Elixir pin, mix_audit, unused swoosh/req |

## Coverage Gaps

None.
