---
module: "ElxMcp.Projects / ElxMcp.DataCase"
date: "2026-08-01"
problem_type: test_failure
component: testing
symptoms:
  - "DBConnection.ConnectionError could not checkout the connection owned by test PID"
  - "Task started from test terminating during Repo.preload"
  - "async: true projects_test failed intermittently on get_ticket"
root_cause: "Ecto preloader used Task (maybe_pmap) which does not share SQL Sandbox ownership with the async test process"
severity: high
tags: [ecto, sandbox, preload, async, testing]
---

# Ecto sandbox breaks on parallel preloads in async tests

## Symptoms

```
** (DBConnection.ConnectionError) could not checkout the connection owned by #PID<...>.
When using the sandbox, connections are shared...
Task #PID started from test terminating
  (ecto) Ecto.Repo.Preloader.fetch_query / maybe_pmap
```

Failed in `ProjectsTest` when `get_ticket` preloaded `[:user_story, :subtasks, :worklogs]`.

## Investigation

1. **Hypothesis**: Missing sandbox setup — false; DataCase was correct.
2. **Hypothesis**: Pool too small — partial; real issue was Task ownership.
3. **Root cause found**: Multi-assoc preload spawns Tasks; sandbox owner is only the test PID.

## Root Cause

With `async: true`, each test owns a DB connection via Sandbox. `Repo.preload/3` may parallelize association loads with `Task`. Those tasks are not checked out as owners → connection errors under race.

## Solution

Force sequential preloads in app code used by async tests:

```elixir
{:ok, Repo.preload(ticket, [:user_story, :subtasks, :worklogs], in_parallel: false)}
```

Alternatively: `async: false` for those tests, or allow ownership to descendants (less precise).

### Files Changed

- `lib/elx_mcp/projects.ex` — `get_epic` / `get_user_story` / `get_ticket` use `in_parallel: false`

## Prevention

- [x] Prefer `in_parallel: false` for multi-assoc preloads in shared lib code
- [ ] testing-reviewer: flag `preload` + `async: true` without sequential option
- Specific: if test fails only under load with Task/preload stacktrace, check sandbox + pmap

## Related

- Ecto.Adapters.SQL.Sandbox docs — ownership modes
