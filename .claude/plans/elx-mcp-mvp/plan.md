# Plan: ElxMCP MVP — Servidor MCP de Status de Projeto

**Status**: COMPLETED (implemented + validated 2026-08-01)  
**Created**: 2026-08-01  
**Detail Level**: deep  
**Input**: `spec/SPEC.md` v0.2 + research (patterns, anubis, ecto, security)

## Summary

Implementar multi-tenant project tracking (estilo Jira) com PostgreSQL em `hermes`, API keys (32 bytes / SHA-256), e servidor MCP read-only (`anubis_mcp`) em `/mcp` com tools + resources bilíngues, CORS, Telemetry e validação por checklist + testes.

## Scope

**In Scope (SPEC MVP):**

- Tabelas e contexts: projects, epics, stories, tickets, boards, sprints, components, comments, attachments, worklogs, changelogs, api_keys
- Issue keys `{PROJECT_KEY}-{N}` com contador transacional
- Auth `X-API-Key`, mix task de geração, isolation por `project_id`
- MCP tools + resources somente leitura + Telemetry
- Seeds, testes, `mix precommit`

**Out of Scope:**

- Tools de escrita, stdio, LiveView admin, OAuth, Jira sync, rate limit obrigatório

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| MCP lib | `anubis_mcp` ~> 1.14 | Phoenix StreamableHTTP, components, maintained |
| Tenant scope | `%Auth.Scope{}` first arg on contexts | Never trust client project_id |
| Frame auth | Plug assigns → Anubis Frame | Official pattern |
| Accept | `json` + `event-stream` | SSE GET for Streamable HTTP |
| CORS | Config origins; plug before auth for OPTIONS | Security report |
| Mix task | `app.config` + `ensure_all_started` | Iron Law #12 |
| binary_id | Enable generators + all schemas | SPEC |
| CORS plug | Lightweight custom plug (no cors_plug dep unless needed) | Prefer zero extra deps |

## Data Model

See research/ecto-schema-report.md. Migration order: projects → boards → sprints → components → epics → user_stories → tickets → component_links → comments → attachments → worklogs → changelogs → api_keys.

## Module Structure

```
lib/elx_mcp/
  tenancy/project.ex, tenancy.ex
  projects/{epic,user_story,ticket,board,sprint,component,component_link}.ex, projects.ex
  collaboration/{comment,attachment,worklog,changelog}.ex, collaboration.ex
  auth/{api_key,scope}.ex, auth.ex
  mcp/server.ex, mcp/tools/*.ex, mcp/resources/*.ex, mcp/telemetry.ex
lib/elx_mcp_web/plugs/{mcp_auth,cors}.ex
lib/mix/tasks/elx_mcp.gen_api_key.ex
```

## Phase 1: Foundation [DONE]

- [x] [P1-T1][direct] Add `anubis_mcp`, enable binary_id/usec timestamps in config
- [x] [P1-T2][ecto] Single migration (or ordered) for all tables + indexes
- [x] [P1-T3][ecto] Schemas + Tenancy (issue keys) + Projects + Collaboration + Auth contexts
- [x] [P1-T4][security] Auth: generate/verify/revoke API keys; Scope struct

## Phase 2: HTTP + MCP [DONE]

- [x] [P2-T1][security] Plugs MCPAuth + CORS; router `/mcp` pipeline
- [x] [P2-T2][direct] Supervise `ElxMcp.MCP.Server`; register tools + resources
- [x] [P2-T3][direct] Read tools: project_status, list/get epics/stories/tickets, search, sprints, boards, comments, changelog
- [x] [P2-T4][direct] Resources project://* + Telemetry on tools

## Phase 3: Seeds, Mix, Tests, Verify [DONE]

- [x] [P3-T1][direct] Mix task `elx_mcp.gen_api_key` + seeds
- [x] [P3-T2][test] Schema/context tests, auth, isolation, issue keys
- [x] [P3-T3][test] Plug auth tests + tool unit tests with Frame assigns
- [x] [P3-T4][test] Validation matrix script + `mix precommit`

## Validation Matrix (acceptance) — see `validation-report.md`

| ID | Criterion (SPEC §8) | Result |
|----|---------------------|--------|
| V01–V17 | Full matrix | **PASS** (`mix precommit`, 26 tests) |

## Session Handoff

- Frame assigns: `project_id`, `api_key_email`, `api_key_id` from plug
- Statuses: backlog, to_do, in_progress, in_review, done, cancelled
- Do not use Mix.Task.run("app.start") in gen_api_key

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Anubis API drift | Pin ~> 1.14; read deps after install |
| Assigns not reaching tools | Integration test frame.assigns |
| Large migration | One migration file, ordered creates |
| CORS * in prod | config_env split |

## Verification Checklist

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix format --check-formatted`
- [ ] `mix test`
- [ ] `mix precommit`
- [ ] Validation matrix V01–V17 all pass
