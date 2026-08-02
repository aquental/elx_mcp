## Requirements Coverage (from plan file elx-mcp-p1-residual)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | [P0-T1] Spike: bind sessions without forking Anubis (Path A/B/C) | MET | Path A chosen: `scratchpad.md`; `lib/elx_mcp/auth/session_bind.ex`; plug-before-Anubis in `mcp_auth.ex:57-88` |
| 2 | [P1-T1] Own rate-limit ETS from Application + opportunistic prune | MET | `application.ex:11` `RateLimit.setup!()`; `rate_limit.ex:19-35` no-op if exists; `maybe_prune/1` at `:88-98` |
| 3 | [P1-T2] Prove counters survive process exit | MET | `test/elx_mcp/auth/rate_limit_test.exs:26-43` spawn/exit then limit still bites |
| 4 | [P1-T3] Session bind Path A (SessionBind + MCPAuth enforce) | MET | Path A implemented: `session_bind.ex` bind/verify/unbind; `mcp_auth.ex:64-93` POST bind, DELETE/GET verify → 403; tests `session_bind_test.exs`, `mcp_auth_test.exs:81-101` |
| 5 | [P1-T3b] (Path C only) Document session residual | MET | N/A Path A; residual still documented in `README.md:7-12` (single-node rate limit + session lifecycle bind notes) |
| 6 | [P2-T1] ID-only resolve: `get_ticket_id` + list_comments/changelog | MET | `projects.ex:340-348`; `list_comments.ex:39-41`; `list_changelog.ex:40-42` use `get_*_id` |
| 7 | [P2-T2] Cap `get_*` association preloads (default 50, max 200) | MET | `projects.ex:8,19-20,146-156,214-223,515-517` query-limited children |
| 8 | [P2-T3] Search fast paths: exact → prefix → title; desc opt-in | MET | `projects.ex:351-395`; tests `projects_test.exs:103-121` exact/desc flag |
| 9 | [P2-T4] Migration `pg_trgm` + GIN on titles | MET | `priv/repo/migrations/20260802120000_enable_pg_trgm_search.exs`; README notes extension rights |
| 10 | [P3-T1] Scope-first public create APIs + authorize_write | MET | `projects.ex` `create_board/sprint/component/epic/user_story/ticket(%Scope{}, …)`; `collaboration.ex:16-87` comment/attachment/worklog/changelog |
| 11 | [P3-T2] Remove `:project_id` from schema casts; put_change in context | MET | e.g. `board.ex:24`, `epic.ex:31-41`, `ticket.ex:41-59`, `comment.ex:26-31` — no `:project_id` in cast |
| 12 | [P3-T3] Enforce `project:write` at mutation boundary | MET | `auth.ex:93-95` `authorize_write/1`; `scope.ex:19` `has_scope?/2`; called from creates |
| 13 | [P5-T1] MCPAuth 429 integration test (async: false) | MET | `test/elx_mcp_web/plugs/mcp_auth_rate_limit_test.exs:26-55` 429 + `retry-after` |
| 14 | [P5-T2] MCP resources tests (Epic/Story/Ticket/Sprint + no scope) | MET | `test/elx_mcp/mcp/resources_test.exs` happy/not_found for 4 resources + unauthorized `:101-105` |
| 15 | [P5-T3] Stronger MCP tool JSON asserts | MET | `tools_test.exs:74-119` list_epics shape, get_ticket key, list_tickets filter, search exact key |
| 16 | [P6-T1] Full suite + format + compile | UNCLEAR | Artifacts present; static review did not re-run `mix test` / format / compile in this pass |
| 17 | [P6-T2] Update residual notes (scratchpad + README limitations) | MET | `scratchpad.md` checklist; `README.md:7-12` Known limitations |

**Path A ↔ P1-T3**: **YES** — Path A session bind fully implements P1-T3 (not Path C defer).

**Summary**: 15 MET · 0 PARTIAL · 0 UNMET · 1 UNCLEAR
