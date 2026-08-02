---
module: "ElxMcp.Auth / ElxMcpWeb.Plugs.MCPAuth"
date: "2026-08-01"
problem_type: security_issue
component: authentication
symptoms:
  - "MCP tools could not safely know which tenant a client belongs to"
  - "Risk of logging plaintext API keys if assigned on conn or frame"
  - "Every request UPDATEd last_used_at causing write amplification"
root_cause: "Bearer secrets need hash-at-rest, per-request verify, Scope-first context, and never putting the plaintext key on assigns or in logs; last_used must be debounced"
severity: high
tags: [mcp, api-key, multi-tenant, sha-256, x-api-key, rate-limit]
elixir_version: "1.17"
phoenix_version: "1.8.9"
---

# MCP multi-tenant API key auth with Scope

## Symptoms

- Need machine clients (Cursor/Claude) to call `/mcp` with one key per project.
- Storing or logging the raw key would leak production credentials.
- Naive `last_used_at` updates on every request hammered Postgres under load.

## Investigation

1. **Hypothesis**: Use Phoenix session auth — rejected; MCP clients send headers only.
2. **Hypothesis**: Store hex key in DB — rejected; must store only SHA-256 of 32-byte secret.
3. **Root cause found**: Need a dedicated `Auth.Scope` resolved by hash lookup and forced onto all tenant queries.

## Root Cause

MCP Streamable HTTP inherits `Plug.Conn.assigns` into Anubis `frame.assigns`. Tenant isolation is only as strong as:

1. Verifying `X-API-Key` before the MCP plug.
2. Putting `project_id` + scopes on assigns (never the plaintext).
3. Every context query filtering `where: project_id == ^scope.project_id`.

## Solution

```elixir
# 32-byte CSPRNG → hex to client once; store hash only
raw = :crypto.strong_rand_bytes(32)
hash = :crypto.hash(:sha256, raw)

# Plug: rate-limit IP, verify, assign Scope, strip header
conn
|> assign(:current_scope, scope)
|> assign(:project_id, scope.project_id)
|> delete_req_header("x-api-key")

# Tools: fail closed if Scope missing or lacks project:read
Helpers.with_scope(frame, fn scope ->
  Projects.list_tickets(scope, opts)
end)
```

Debounce `last_used_at` (≥60s) and ETS rate-limit per IP (429).

### Files Changed

- `lib/elx_mcp/auth.ex` — generate/verify/revoke + debounce
- `lib/elx_mcp/auth/scope.ex` — `%Scope{}`
- `lib/elx_mcp_web/plugs/mcp_auth.ex` — X-API-Key + rate limit + strip header
- `lib/elx_mcp/auth/rate_limit.ex` — ETS window limiter
- `lib/elx_mcp/mcp/helpers.ex` — `scope_from_frame` / `with_scope`

## Prevention

- [x] Prefer `%Scope{}` first arg on all tenant reads
- [ ] Add rate-limit + key-in-headers checks to security-analyzer prompts
- [x] Tests: verify, revoke, missing `project:read`, isolation
- Specific: never `assign(:api_key, plaintext)`; never log `frame.context.headers`

## Related

- `.claude/solutions/ecto-issues/same-tenant-fk-validation-20260801.md`
- Iron Law: pin `^` in queries; no `String.to_atom` on user input
