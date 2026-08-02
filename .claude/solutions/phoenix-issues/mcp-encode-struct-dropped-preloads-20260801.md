---
module: "ElxMcp.MCP.Helpers"
date: "2026-08-01"
problem_type: logic_error
component: phoenix_context
symptoms:
  - "get_epic/get_ticket preloaded children but MCP JSON had no nested stories/tickets"
  - "Wasted DB preloads with empty client payload"
  - "Review finding: encode_struct always Map.drop associations"
root_cause: "Serializer treated associations as noise and dropped them after Map.from_struct, so loaded data never reached Response.json"
severity: medium
tags: [mcp, serialization, preload, anubis, encode-struct]
---

# MCP encode_struct must not drop loaded associations

## Symptoms

- Code called `Repo.preload(epic, [:user_stories])` then `Helpers.encode_struct(epic)`.
- Tool response JSON lacked `user_stories` / `tickets` / `subtasks`.
- Code review flagged preloads as pure waste.

## Investigation

1. **Hypothesis**: Anubis Response.json drops maps — false; it encodes any JSON data.
2. **Hypothesis**: Preload failed in tests — false; associations loaded on struct.
3. **Root cause found**: `encode_struct/1` explicitly `Map.drop`ped association keys.

## Root Cause

```elixir
# BAD — always removes nested data even when preloaded
|> Map.drop([:user_stories, :tickets, :subtasks, :worklogs, :epic, ...])
```

Ecto puts associations on the struct. Serialization that drops those keys by name throws away intentional preloads. Only `__meta__` and true cycles (e.g. parent) need special handling; `NotLoaded` should become `nil` or be rejected.

## Solution

```elixir
@drop_always ~w(__meta__)a
@drop_parents ~w(project parent_ticket)a  # avoid deep/circular graphs

def encode_struct(struct) when is_struct(struct) do
  struct
  |> Map.from_struct()
  |> Map.drop(@drop_always ++ @drop_parents)
  |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
  |> Map.new(fn {k, v} -> {k, encode_value(v)} end)
end
```

Loaded associations recurse via `encode_value/1` → nested maps for the MCP client.

### Files Changed

- `lib/elx_mcp/mcp/helpers.ex` — encode policy
- `test/elx_mcp/mcp/tools_test.exs` — assert nested content on get_ticket

## Prevention

- [ ] Reviewer rule: if preload + encode_struct, check drop list
- [x] Prefer rejecting `NotLoaded` over dropping association names
- Specific: only drop circular parents; encode the rest

## Related

- `.claude/solutions/testing-issues/ecto-sandbox-parallel-preload-20260801.md`
