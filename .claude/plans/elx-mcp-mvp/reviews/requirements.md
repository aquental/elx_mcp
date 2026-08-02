## Requirements Coverage (from SPEC v0.2 + plan elx-mcp-mvp)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | Migrations: projects, epics, user_stories, tickets, boards, sprints, components, component_links, comments, attachments, worklogs, changelogs, api_keys on Postgres `hermes` | MET | `priv/repo/migrations/20260801200000_create_project_domain.exs:5-267` (13 tables); `config/dev.exs:9` + `config/test.exs:11` `hostname: "hermes"` |
| 2 | Jira `projects.issue_counter` generates `{KEY}-{N}` without collision | MET | `lib/elx_mcp/tenancy.ex:29-44` (`FOR UPDATE` + increment); `test/elx_mcp/validation_matrix_test.exs:28-31` |
| 3 | Story without epic OK; ticket without story rejected | MET | nullable `epic_id` migration `:98`; ticket required `user_story_id` `lib/elx_mcp/projects/ticket.ex:61`; tests `validation_matrix_test.exs:33-38` |
| 4 | Sub-tasks via `parent_ticket_id` with cycle validation | MET | create path + `validate_parent_cycle` `lib/elx_mcp/projects.ex:126-127,256-282`; subtask parent `ticket.ex:74-78`; matrix `validation_matrix_test.exs:40-49` (cycle logic present; no dedicated cycle test) |
| 5 | API key: 32 bytes, SHA-256, `project_id`+`email`; mix `elx_mcp.gen_api_key` | MET | `lib/elx_mcp/auth.ex:13-17`; task `lib/mix/tasks/elx_mcp.gen_api_key.ex:7,15-32` |
| 6 | Multiple keys per email; revoke; no default expiry | MET | multi create `auth.ex:13`; revoke `auth.ex:64-67`; schema has `revoked_at` no `expires_at` `lib/elx_mcp/auth/api_key.ex:11-19`; matrix `validation_matrix_test.exs:51-57` |
| 7 | `anubis_mcp` server at `/mcp` (Streamable HTTP) same app | MET | dep `mix.exs:76`; supervise `lib/elx_mcp/application.ex:15`; route `lib/elx_mcp_web/router.ex:17-32`; server `lib/elx_mcp/mcp/server.ex:6-9` |
| 8 | Read tools + resources from SPEC §6; auth `X-API-Key` | PARTIAL | 12 tools registered `mcp/server.ex:12-23`; resources status/epics/stories/tickets `server.ex:26-29` + `resources/*.ex`; **missing** `project://sprints/{id_or_name}`; auth plug `lib/elx_mcp_web/plugs/mcp_auth.ex:15-32` |
| 9 | `project_status` returns counts + N recent | MET | tool `lib/elx_mcp/mcp/tools/project_status.ex:18-25`; summary `lib/elx_mcp/projects.ex:205-216`; test `projects_test.exs:72-79` |
| 10 | Key sees entire project (no assignee filter) | MET | list/get scoped by `project_id` only e.g. `projects.ex:63,99,139`; isolation `projects_test.exs:59-69` |
| 11 | MCP descriptions bilingual (PT/EN) | MET | e.g. `mcp/tools/project_status.ex:2-5`, `list_epics.ex:2-3`, `search_work_items.ex:2-3`; matrix `validation_matrix_test.exs:66-77` |
| 12 | Configurable CORS enabled | MET | plug `lib/elx_mcp_web/plugs/cors.ex:3-11`; pipeline `router.ex:19`; config `config/config.exs:14`, `config/dev.exs:4` |
| 13 | Telemetry on MCP tools | MET | `lib/elx_mcp/mcp/helpers.ex:42-49` `[:elx_mcp, :mcp, :tool, :stop]`; used in tools e.g. `project_status.ex:24` |
| 14 | Seeds: 1 project, board, sprint, epic, 2 stories, 4 tickets, comment/changelog, demo API key | MET | `priv/repo/seeds.exs:5-153` |
| 15 | Tests: schemas/contexts, gen key, auth plug, issue keys, multi-tenant isolation | MET | `test/elx_mcp/{tenancy,projects,auth,collaboration,validation_matrix}_test.exs`; `test/elx_mcp_web/plugs/mcp_auth_test.exs`; `test/elx_mcp/mcp/tools_test.exs` |
| 16 | `mix precommit` clean | UNCLEAR | alias defined `mix.exs:99`; this review did not re-run the command (runtime gate) |

**Summary**: 13 MET · 1 PARTIAL · 0 UNMET · 1 UNCLEAR
