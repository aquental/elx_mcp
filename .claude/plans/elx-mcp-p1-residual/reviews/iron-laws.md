# Iron Law Violations Report

## Summary
- Files scanned: ~40 under `lib/elx_mcp/**`, `lib/elx_mcp_web/plugs/mcp_auth.ex` (auth, collaboration, projects, schemas, MCP tools/resources, plugs)
- Iron Laws checked: 19 of 26 applicable (no LiveView, no Oban workers, no mix tasks, no HEEx in scope)
- Violations found: **0** (0 critical, 0 high, 0 medium)

## Scope scanned

| Area | Paths |
|------|--------|
| Auth / rate / session | `auth.ex`, `auth/*`, `plugs/mcp_auth.ex` |
| Contexts | `projects.ex`, `collaboration.ex`, `tenancy.ex`, `catalog.ex` |
| Schemas | `projects/*`, `collaboration/*`, `tenancy/project.ex`, `auth/api_key.ex` |
| MCP | `mcp/helpers.ex`, `mcp/server.ex`, `mcp/tools/*`, `mcp/resources/*` |
| App | `application.ex` |

## Critical Violations

_(none)_

## High Violations

_(none)_

## Medium Violations

_(none)_

## Notes (not violations — for orchestrator context)

Patterns verified clean (no reportable findings):

- **#5 Pin values**: All `from`/`where` use `^` on external values (`project_id`, keys, filters, ILIKE patterns). `escape_like/1` used before `%` wildcards.
- **#10 String.to_atom**: No `String.to_atom/1` in `lib/`.
- **#4 Money float**: No `:float` money fields; time is integer seconds.
- **#12 raw/1**: No `raw/`.
- **#14 Cross joins**: No multi-source `from` without `on:`.
- **Mutations / #11 analogue**: `Projects`/`Collaboration` writes call `Auth.authorize_write/1`; schemas do not cast `:project_id` (set via `put_change`).
- **#1–3 LiveView / #7–9 Oban / #16 Mix**: N/A in this diff.
- **MCP tools**: `Helpers.with_scope/2` gates reads on `project:read`; `{:error, _}` in list_comments/changelog is entity resolve, not changeset form handling.

Checked 19 of 26 Iron Laws: 0 violations found.
