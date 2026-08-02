# Iron Law Violations Report

## Summary
- Files scanned: ~45 (`lib/elx_mcp/**`, `lib/elx_mcp_web/plugs/**`, `router.ex`, `lib/mix/tasks/elx_mcp.gen_api_key.ex`, migration)
- Iron Laws checked: 19 of 26 (LiveView #1–3, #11, #17 N/A — no LiveViews; Oban #7–9b N/A — no workers)
- Violations found: **0** (0 critical, 0 high, 0 medium)

Checked N/A or clean for this MVP surface:

| Law | Result |
|-----|--------|
| #4 float money | Clean — time as integer seconds; no money fields |
| #5 pin `^` in queries | Clean — all `from`/`where` use `^` |
| #6 has_many JOIN | Clean — `Repo.preload` for `user_stories`/`tickets`/`subtasks`/`worklogs` |
| #10 `String.to_atom` | Clean — none in `lib/` |
| #12 `raw/1` | Clean — none |
| #14 implicit cross join | Clean — no multi-source `from` |
| #15 `@external_resource` | Clean — no compile-time `File.read!` |
| #16 Mix `app.start` | Clean — `app.config` + `Application.ensure_all_started(:elx_mcp)` |
| #13 unsupervised GenServer | Clean — children under `ElxMcp.Supervisor` only |

## Critical Violations

_None._

## High Violations

_None._

## Medium Violations

_None._

## Notes (non-violations, informational)

1. **`{:error, _}` in MCP tools** (`list_comments.ex:32`, `list_changelog.ex:33`): entity resolution only returns `:not_found` / `:invalid_type`, not changesets — Iron Law #17 does not apply.
2. **Auth model**: plug `MCPAuth` + `Helpers.with_scope/2` gates all tools/resources; `Scope.has_scope?/2` exists but is unused (read-only MVP; re-check if write scopes are added).
3. **Mix task** `elx_mcp.gen_api_key` correctly avoids full `app.start`.
