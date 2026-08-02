---
module: "ElxMcp.Projects"
date: "2026-08-01"
problem_type: database_issue
component: ecto_schema
symptoms:
  - "DB foreign keys allowed ticket.user_story_id from another project"
  - "Multi-tenant integrity only on row existence, not project_id match"
  - "Review WARNING: cross-project association poisoning"
root_cause: "Standard references() FKs do not enforce that parent and child share the same project_id; app must validate same-tenant before insert"
severity: high
tags: [multi-tenant, foreign-key, ecto, isolation]
---

# Same-tenant association validation beyond DB FKs

## Symptoms

- Ticket could reference a `user_story_id` belonging to project B while `project_id` was project A.
- PostgreSQL FK only checks that the story row exists.

## Investigation

1. **Hypothesis**: Composite FKs in Postgres — possible but heavy for MVP.
2. **Hypothesis**: Trust only MCP read path — unsafe once any write path exists.
3. **Root cause found**: No app-level `project_id` match on association IDs.

## Root Cause

```sql
-- FK: user_stories.id must exist
-- Does NOT require user_stories.project_id = tickets.project_id
```

Multi-tenant models need either composite FKs `(project_id, id)` or application checks.

## Solution

```elixir
defp ensure_same_project(_schema, nil, _project_id), do: :ok

defp ensure_same_project(schema, id, project_id) do
  case Repo.get_by(schema, id: id, project_id: project_id) do
    nil -> {:error, :invalid_association}
    _ -> :ok
  end
end

# In create_ticket/create_user_story/create_sprint:
with :ok <- ensure_same_project(UserStory, attrs[:user_story_id], project_id),
     :ok <- ensure_same_project(Ticket, attrs[:parent_ticket_id], project_id) do
  ...
end
```

### Files Changed

- `lib/elx_mcp/projects.ex` — `ensure_same_project/3` on creates
- `test/elx_mcp/projects_test.exs` — cross-tenant association rejection

## Prevention

- [ ] Always validate association `project_id` in multi-tenant writes
- [ ] Prefer `%Scope{}` on mutations; set `project_id` via `put_change`, not cast
- Specific: never trust client-supplied parent IDs without tenant filter

## Related

- `.claude/solutions/security-issues/mcp-api-key-tenant-scope-auth-20260801.md`
