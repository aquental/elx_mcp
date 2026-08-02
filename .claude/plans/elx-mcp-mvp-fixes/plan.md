# Plan: ElxMCP Review Fixes (from triage)

**Status**: COMPLETED (fixes implemented; mix precommit 37 passed)  
**Created**: 2026-08-01  
**Input**: `.claude/plans/elx-mcp-mvp/reviews/elx-mcp-mvp-triage.md`

## Summary

Close review REQUIRES CHANGES: harden multi-tenant writes/scopes/MCP encoding, security ops (rate limit, last_used, CORS, key context), add sprints resource, expand tests.

## Phase 1: Code correctness [PENDING]

- [ ] [P1-T1][direct] Fix encode_struct nested associations; fail-closed scope; has_scope in with_scope
- [ ] [P1-T2][direct] List tools: not-found on bad epic/story key; limits on boards/sprints/comments
- [ ] [P1-T3][ecto] Same-tenant FK validation on creates; put_change for project_id/key; atomic worklog inc
- [ ] [P1-T4][security] Scope allowlist; debounce last_used; simple rate limit; CORS refuse * in prod; strip x-api-key from assigns if possible
- [ ] [P1-T5][direct] Sprints resource project://sprints/{id_or_name}

## Phase 2: Tests [PENDING]

- [ ] [P2-T1][test] Projects API: boards/sprints/epics/search/cycle + isolation expansion
- [ ] [P2-T2][test] MCP tools/resources remaining + not-found
- [ ] [P2-T3][test] Auth scope deny; collaboration isolation/attachment; OPTIONS plug
- [ ] [P2-T4][test] E2E /mcp if feasible with supervised Anubis server

## Phase 3: Verify [PENDING]

- [ ] [P3-T1][test] mix precommit clean

## Verification

- [ ] mix compile --warnings-as-errors
- [ ] mix test
- [ ] mix precommit
