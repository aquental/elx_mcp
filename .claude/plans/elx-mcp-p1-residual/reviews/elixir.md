# Code Review: ElxMCP P1 residual

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 9 (0 blocker, 6 warning, 3 suggestion)
- **Focus**: RateLimit/SessionBind ETS, scope-first writes, search, child_limit, list_comments/changelog ID resolve

P1 goals are largely met: Application owns ETS tables, mutations take `%Scope{}` + `authorize_write`, `project_id`/`key` set via `put_change`, search is exact→prefix→title, `get_*` caps children, tools use `get_*_id`.

---

## Critical Issues (BLOCKER)

_None._

---

## Warnings

### 1. `SessionBind` / `RateLimit` — create-on-miss from request process
**`lib/elx_mcp/auth/session_bind.ex:39,71,85,92`**, **`lib/elx_mcp/auth/rate_limit.ex:80-85`**

`Application.start/2` correctly creates both tables, but every `SessionBind` API still calls `setup!()`, and `RateLimit.check/2` calls `ensure_table!()`. If the named table is ever missing, the **calling process** becomes owner — the original “table dies with request” failure mode returns.

```elixir
# Prefer hard fail if Application did not install the table
defp ensure_table! do
  case :ets.whereis(@table) do
    :undefined -> raise "ETS #{@table} missing — call setup! from Application.start/2"
    _ -> :ok
  end
end
```

Keep `setup!/0` only for Application + test setup.

### 2. `SessionBind` — no TTL / prune (unbounded ETS)
**`lib/elx_mcp/auth/session_bind.ex`**

RateLimit prunes old buckets; SessionBind never deletes except explicit `unbind` on DELETE. Abandoned clients leave `session_id` entries forever (single-node memory growth).

Add opportunistic prune (timestamp column + max age) or size cap, analogous to `RateLimit.maybe_prune/1`.

### 3. Unbound sessions fail-open on lifecycle
**`lib/elx_mcp/auth/session_bind.ex:75`**, **`lib/elx_mcp_web/plugs/mcp_auth.ex:68-82`**

`verify/3` returns `:ok` when unbound. Initialize often creates a session id **in the response** (request has no `mcp-session-id`), so the first POST does not bind. Until a later POST with that id, any authenticated principal who knows the id can GET SSE or DELETE through Anubis.

Documented Path A residual if session ids are high-entropy; still worth binding on first response path later (or reject lifecycle ops when unbound).

### 4. `list_changelog/4` limit uncapped
**`lib/elx_mcp/collaboration.ex:89-99`**

```elixir
# Current
limit = Keyword.get(opts, :limit, 50)

# Suggested (mirror list_comments)
limit = Keyword.get(opts, :limit, 50) |> min(200) |> max(1)
```

MCP schema max is 100; context API still allows huge limits.

### 5. Collaboration writes do not validate entity tenancy
**`lib/elx_mcp/collaboration.ex:16-24,39-46,75-86`**

`create_comment` / `create_attachment` / `record_changelog` set `project_id` from scope but never check `commentable_id` / `entity_id` exists in that project (unlike `Projects.ensure_same_project/3`). Cross-tenant **read** IDOR is blocked by list filters; still allows orphan rows and wrong-type ids. Prefer `ensure_same_project` (or type-specific resolve) before insert.

### 6. `Ticket` mass-assigns `time_spent_seconds`
**`lib/elx_mcp/projects/ticket.ex:51`**

`:time_spent_seconds` is in `cast/3` while worklogs use `increment_time_spent/3`. Clients can forge spent time on `create_ticket`. Drop from cast; default schema `0` + atomic inc only.

---

## Suggestions

### 1. Search still up to 9 queries per call
**`lib/elx_mcp/projects.ex:416-511`**

Exact/prefix/title each hit epics + stories + tickets even when earlier stages fill `limit`. Short-circuit after `length(exact) >= limit`, and consider `UNION ALL` + single `LIMIT` for prefix/title.

### 2. Fail-open catch-alls on SessionBind
**`lib/elx_mcp/auth/session_bind.ex:61,81`**

`bind_if_new(_, _, _), do: :ok` and `verify(_, _, _), do: :ok` silently skip when args are invalid. Prefer `{:error, :invalid_session}` (or no catch-all) so nil/empty ids never skip the guard.

### 3. `search_work_items` tool vs description
**`lib/elx_mcp/mcp/tools/search_work_items.ex:3-4,21`**

Moduledoc mentions description search; tool never passes `include_description: true`. Align docs or add an opt-in field (default false is correct).

---

## Pre-existing (one-line)

- `lib/elx_mcp/projects.ex:292` — `increment_time_spent/3` takes bare `project_id` (no Scope); OK if only Multi-internal.
- `lib/elx_mcp/mcp/helpers.ex:12-43` — dual scope resolution from assigns vs `%Scope{}` (compat layer).
- `lib/elx_mcp/auth.ex:126-137` — `touch_last_used` fire-and-forget `update_all` (debounce OK).

---

## Checklist notes (diff-relevant)

| Area | Verdict |
|------|---------|
| Scope-first creates + `authorize_write` | OK |
| `put_change(:project_id)` / no cast of `project_id`/`key` | OK on touched schemas |
| `get_ticket_id` + list_comments/changelog | OK |
| `child_limit` default 50 / max 200 | OK |
| Search exact → prefix → title; desc opt-in | OK |
| RateLimit Application setup + prune + survive-exit test | OK |
| SessionBind Path A plug + insert_new race | OK for bind race |
| ETS create-on-miss / SessionBind growth / unbound lifecycle | See warnings |
