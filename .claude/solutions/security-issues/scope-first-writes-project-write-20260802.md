---
module: "ElxMcp.Projects"
date: "2026-08-02"
problem_type: security_issue
component: authorization
symptoms:
  - "create_* APIs accepted bare project_id with no project:write check"
  - "Schemas cast :project_id enabling latent mass-assignment IDOR before write MCP tools"
  - "Catalog defined project:write but mutation boundary never enforced it"
root_cause: "Public mutation APIs used project_id arity and schema cast lists included tenant fields instead of Scope + put_change + authorize_write"
severity: high
tags: [scope, authorization, mass-assignment, project-write, changeset]
---

# Scope-first mutations with project:write and no project_id cast

## Symptoms

- Audit residual: write surfaces could accept a raw `project_id` and cast it from attrs — latent IDOR once write MCP tools or callers appear.
- `project:write` existed in the catalog but was unused at the mutation boundary.
- Ticket already used `put_change` for `project_id`/`key`; other schemas still casted them.

## Investigation

1. Keep private `project_id` arity for seeds only — Elixir `defp` is not callable from seeds/mix; public Scope API + write scope in seeds is cleaner.
2. `:ok = authorize_write!` that raises — prefer `{:error, :forbidden}` with `with`.
3. **Root cause**: tenant id and issue keys must never be mass-assigned; write capability must be checked at context entry.

## Root Cause

Defense in depth for multi-tenant writes requires:

1. Authenticated **Scope** as first argument (project_id from scope, not attrs).
2. Explicit **scope string** check (`project:write`).
3. Changeset **cast deny-list** for tenant fields (`project_id`, issue `key`) set only via `put_change`.

## Solution

```elixir
def create_epic(%Scope{} = scope, attrs) do
  with :ok <- Auth.authorize_write(scope) do
    do_create_epic(scope.project_id, attrs)
  end
end

defp do_create_epic(project_id, attrs) do
  with {:ok, key} <- Tenancy.next_issue_key(project_id) do
    %Epic{}
    |> Epic.changeset(attrs)  # no :project_id or :key in cast
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> Ecto.Changeset.put_change(:key, key)
    |> Repo.insert()
  end
end

def authorize_write(%Scope{} = scope) do
  if Scope.has_scope?(scope, "project:write"), do: :ok, else: {:error, :forbidden}
end
```

Collaboration extras:

- Resolve entity id **in project** before comment/attachment/worklog/changelog insert.
- Force `author_email` / `actor_email` from `scope.actor_email`.

### Files Changed

- `lib/elx_mcp/projects.ex`, `lib/elx_mcp/collaboration.ex`
- Schema cast lists under `projects/*`, `collaboration/*`
- Seeds + tests use write scopes `["project:read", "project:write"]`

## Prevention

- [x] Tests assert `{:error, :forbidden}` without `project:write`
- [ ] When write MCP tools ship, never bypass context `authorize_write`
- Specific guidance: Mirror Ticket's put_change pattern for every tenant-sensitive field; never cast `project_id`.

## Related

- `.claude/solutions/security-issues/mcp-api-key-tenant-scope-auth-20260801.md`
- `.claude/solutions/ecto-issues/same-tenant-fk-validation-20260801.md`
