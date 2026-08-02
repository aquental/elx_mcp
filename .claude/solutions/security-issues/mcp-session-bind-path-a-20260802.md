---
module: "ElxMcp.Auth.SessionBind"
date: "2026-08-02"
problem_type: security_issue
component: authentication
symptoms:
  - "Any authenticated principal could DELETE or attach SSE to another client's mcp-session-id"
  - "Anubis StreamableHTTP owns session lifecycle with no app hook for principal metadata"
  - "Tool tenant isolation was sound, but session lifecycle was only keyed by session id"
root_cause: "Anubis DELETE/GET use session id alone; no binding of session_id to {api_key_id, project_id} without forking Anubis"
severity: high
tags: [mcp, session, anubis, ets, plug, authorization]
---

# Bind MCP sessions to API key without forking Anubis (Path A)

## Symptoms

- MCP Streamable HTTP sessions (`mcp-session-id`) could be disrupted by another valid API key holder who knew or guessed the session id (DELETE closes session; GET registers SSE).
- Tool handlers already re-authenticated and scoped every POST — **data IDOR was not the issue**; lifecycle DoS / hijack was.
- Forking Anubis was out of scope; no first-class session-metadata hook was available.

## Investigation

1. **Hypothesis**: patch Anubis `handle_delete` — rejected (fork cost).
2. **Hypothesis**: Path B Anubis config for session owner — none found suitable.
3. **Root cause found / Path A**: Router runs `MCPAuth` **before** `forward` to Anubis. Plug can see method + session header + authenticated scope and halt 403 before Anubis runs.

## Root Cause

Session lifecycle is protocol-level (initialize → session id → DELETE/SSE). Anubis keys runtime session by id only. Application must maintain a parallel registry: `session_id → {api_key_id, project_id}` and enforce ownership on lifecycle methods.

## Solution

**Path A — app-owned ETS registry + plug guard:**

1. `SessionBind` ETS (Application-owned, same ownership rule as RateLimit).
2. **POST** with `mcp-session-id`: `bind_if_new/3` (first binder wins; refresh TTL).
3. **DELETE/GET** with session header: `verify_owner/3` **fail-closed** if unbound, expired, or foreign → 403.
4. Owner DELETE also `unbind/1`.
5. 30m TTL + opportunistic prune (align with Anubis idle timeout).

```elixir
# mcp_auth.ex (after verify_api_key success)
case conn.method do
  "POST" when session_id != nil ->
    case SessionBind.bind_if_new(session_id, scope.api_key_id, scope.project_id) do
      :ok -> conn
      {:error, _} -> forbidden(conn)
    end

  "DELETE" when session_id != nil ->
    case SessionBind.verify_owner(session_id, scope.api_key_id, scope.project_id) do
      :ok -> SessionBind.unbind(session_id); conn
      {:error, _} -> forbidden(conn)
    end

  "GET" when session_id != nil ->
    case SessionBind.verify_owner(...) do
      :ok -> conn
      {:error, _} -> forbidden(conn)
    end
end
```

Clients must POST (with session header) at least once after initialize so DELETE/GET succeed. That is intentional fail-closed hardening.

### Files Changed

- `lib/elx_mcp/auth/session_bind.ex` — NEW registry
- `lib/elx_mcp_web/plugs/mcp_auth.ex` — lifecycle enforce
- `lib/elx_mcp/application.ex` — `SessionBind.setup!()`
- `test/elx_mcp_web/plugs/mcp_auth_session_test.exs` — POST/DELETE/GET 403 + unbind (`async: false`)

## Prevention

- [ ] Prefer supervised owner process if multi-table ETS grows
- [ ] Multi-node: sticky sessions or Redis (document single-node residual)
- [x] Plug tests for foreign principal on POST/DELETE/GET must use correct HTTP method (ConnCase defaults to GET)
- Specific guidance: Never fork Anubis for session metadata if a pre-forward plug can gate lifecycle; always Application-own the bind table.

## Related

- `.claude/solutions/otp-issues/rate-limit-ets-owned-by-request-process-20260802.md`
- `.claude/solutions/security-issues/mcp-api-key-tenant-scope-auth-20260801.md`
- Plan: `.claude/plans/elx-mcp-p1-residual/plan.md` P0-T1 / P1-T3
