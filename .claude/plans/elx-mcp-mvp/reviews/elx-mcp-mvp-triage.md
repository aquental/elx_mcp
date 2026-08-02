# Triage: ElxMCP MVP Review

**Date**: 2026-08-01  
**Source review**: `.claude/plans/elx-mcp-mvp/reviews/elx-mcp-mvp-review.md`  
**User approach**: Plan first, then fix (full review scope)

## Selection summary

| Category | Decision |
|----------|----------|
| Iron Law auto-approve | None (0 violations) |
| All BLOCKERs (5) | **Fix** |
| All WARNINGs (~19) | **Fix** |
| PARTIAL: sprints resource | **Fix** |
| Explicit individuals | B1–B5, encode_struct, silent filters (subset of above) |

**Scope**: Full fix queue from review (blockers + warnings + sprints resource).  
**Approach**: `/phx:plan` from this triage file → then implement.

## Fix Queue (approved)

### Coverage / tests

- [ ] **B1** Projects public API tests — boards, sprints, components, epics, search, cycle  
- [ ] **B2** MCP tools/resources tests — remaining 10 tools + 4 resources + not-found  
- [ ] **B3** Authenticated E2E `/mcp` (or supervised transport) with valid key  
- [ ] **B4** Auth: deny missing `project:read`; non-binary verify  
- [ ] **B5** Collaboration: attachment, cross-tenant list isolation, worklog accumulation  

### Requirements PARTIAL

- [ ] **R8** Add resource `project://sprints/{id_or_name}`  

### High-impact code / security (from WARNINGs)

- [ ] **W5** `encode_struct` — return nested summaries or stop wasteful preloads  
- [ ] **W6** Invalid story/epic key → error not silent `[]`  
- [ ] **W1/W2** Same-tenant FK checks; prefer Scope on mutations; stop casting server-owned fields  
- [ ] **W16** Atomic worklog `time_spent_seconds` (`inc` / row lock)  
- [ ] **W7** Default/max limits on boards/sprints/comments lists  
- [ ] **W8** Prefer `current_scope`; fail closed if scopes missing  
- [ ] **W9** Mitigate plaintext key in Anubis context (strip/document/no log)  
- [ ] **W10** Rate limit `/mcp` + debounce `last_used_at`  
- [ ] **W11** Body size / parser risk on unauth MCP (document or limit)  
- [ ] **W12** CORS: refuse `*` in prod path; tighten defaults  
- [ ] **W13** Allowlist scopes; re-check `has_scope?` in tools  
- [ ] **W14–W15** Optional hardening: timing, serialize_assigns  
- [ ] Remaining testing WARNINGs (OPTIONS, matrix strength, tenancy concurrency) as time allows  

## Skipped

_None selected as skip._

## Deferred

_None explicitly deferred. Lower suggestions (search cost, factories, issue key gaps) may land in plan Phase “polish” if time-boxed._

## Next steps

1. **Plan fixes** — `/phx:plan .claude/plans/elx-mcp-mvp/reviews/elx-mcp-mvp-triage.md`  
2. **Then implement** — `/phx:work` on that plan  
3. Re-run `/phx:review` or `mix precommit` after  
4. Optionally `/phx:compound` for durable patterns (API key isolation, encode_struct)

---

Triage complete: **~25 items to fix**, **0 skipped**, **0 deferred**.
