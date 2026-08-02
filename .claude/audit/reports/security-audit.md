# Security Audit: ElxMCP

**Date:** 2026-08-01  
**Scope:** Auth (`lib/elx_mcp/auth*`), MCP plugs, MCP tools/resources (tenant isolation), `config/runtime.exs` / `dev.exs`, API-key mix tasks  
**Auth model reviewed:** `X-API-Key` + `X-Email` must match key owner; SHA-256 of 32-byte keys; `project_id` scope via frame assigns  

## Executive Summary

ElxMCP’s API-key auth and tenant isolation are **fundamentally sound** for a read-only multi-tenant MCP server: dual headers, high-entropy keys, hash-at-rest, header scrubbing, and consistent `project_id` filters in contexts. Production CORS defaults and `force_ssl` are reasonable.

Main risks are **infra TLS defaults** (`DB_SSL=verify_none`), **MCP session IDs not bound to the API key** (Anubis entropy + cross-session DELETE), and a **weak/single-node rate limiter**. No critical SQL injection, atom exhaustion, or XSS sinks found in scope.

## Security Score: **72 / 100**

| Band | Meaning |
|------|---------|
| 90–100 | Hardened production posture |
| 70–89 | Solid core; fix listed issues before scale-out |
| &lt;70 | Material authz/authn gaps |

---

## Critical Vulnerabilities

*None found in application code paths reviewed.*  
No SQL interpolation of user input, no `String.to_atom/1` on input, no `raw/1` / unsafe term decode, no unscoped MCP reads.

---

## High

### 1. DB TLS defaults to certificate verification off

- **Severity**: High  
- **Location**: `config/runtime.exs` (`DB_SSL` default `"verify_none"`)  
- **Issue**: Postgres SSL is enabled with `verify: :verify_none` unless operators set `DB_SSL=true`. A network attacker (or compromised proxy) can MITM the DB connection and observe/modify tenant data and `key_hash` rows.  
- **OWASP**: A02 Cryptographic Failures  
- **Fix**:

```elixir
# Prefer verify peer in prod; only allow verify_none via explicit opt-in
case {config_env(), System.get_env("DB_SSL", "true")} do
  {:prod, v} when v in ~w(true 1 yes) ->
    [verify: :verify_peer, cacertfile: System.fetch_env!("DB_CA_CERT")]
  {_, "verify_none"} ->
    [verify: :verify_none]  # dev/test only
  ...
end
```

Document required `DB_CA_CERT` / platform CA bundle for managed Postgres.

---

## Medium

### 2. MCP sessions not bound to `api_key_id` / weak session ID entropy

- **Severity**: Medium  
- **Location**: `ElxMcpWeb.Plugs.MCPAuth` + Anubis `StreamableHTTP.Plug` / `Anubis.MCP.ID.generate_session_id/0`  
- **Issue**:
  1. Every request re-auths (good), but **session lifecycle** (SSE register, restore, **DELETE**) is keyed only by `mcp-session-id`, not by the authenticated key/tenant.
  2. Anubis session IDs use **24 bits of pure random** plus timestamp/phash2 — far weaker than the API key. A leaked or guessed session id from any authenticated principal can **terminate** another client’s session (`DELETE /mcp`) or attach to shared session process state.
- **OWASP**: A01 Broken Access Control / A07 Identification & Auth Failures  
- **Fix**:
  - Bind session → `{api_key_id, project_id}` at create; reject or re-key if headers disagree.
  - On DELETE/GET SSE, require same binding.
  - Prefer cryptographically random session ids (e.g. 128-bit+) if configuring/customizing transport.

### 3. Rate limiter: IP-only, non-atomic, non-distributed

- **Severity**: Medium  
- **Location**: `lib/elx_mcp/auth/rate_limit.ex`, used from `mcp_auth.ex`  
- **Issue**:
  - Cap is **per `remote_ip` only** (not per key/email) — shared NATs throttle everyone; distributed keys behind one IP share budget.
  - ETS read-modify-write is **not atomic** under concurrency (limit can be exceeded).
  - Table is **local** — multi-node deployments multiply effective budget.
  - No `x-forwarded-for` / trusted-proxy handling; behind reverse proxies without Bandit/`remote_ip` config, many clients may share one IP (or rate limit becomes ineffective if IP is always the LB).
  - Unbounded keys in ETS (one entry per IP forever, filtered list only) → memory pressure under IP churn.
- **OWASP**: A04 Insecure Design / availability  
- **Fix**: Atomic counters (`:ets.update_counter` or Hammer/Nebulex), key by `{ip, api_key_id}` after auth (and stricter bucket on failed auth), configure trusted proxies, periodic prune or TTL.

### 4. API keys never expire

- **Severity**: Medium  
- **Location**: `lib/elx_mcp/auth/api_key.ex`, `auth.ex` (only `revoked_at`)  
- **Issue**: Compromised keys remain valid indefinitely until manual revoke. No `expires_at`, rotation policy, or max lifetime.  
- **OWASP**: A07  
- **Fix**: Add `expires_at`; enforce in `fetch_active_key/1`; document rotation via `mix elx_mcp.gen_api_key` + revoke old.

### 5. Latent tenant write hazard: `project_id` is castable

- **Severity**: Medium (latent — no MCP write tools today)  
- **Location**: `Projects.*` / `Collaboration.*` changesets cast `:project_id`; create helpers take raw `project_id`  
- **Issue**: Schemas allow client-supplied `project_id` in `cast/3`. Contexts currently `Map.put(:project_id, project_id)`, which is usually safe, but dual string/atom keys in attrs can make Ecto param conversion ambiguous. When `project:write` tools are added, mass-assignment IDOR is a high risk.  
- **OWASP**: A01  
- **Fix**: Never cast `:project_id`; set only via `put_change/3` from `%Scope{}`. Prefer `create_*(%Scope{}, attrs)` signatures for all mutations.

---

## Low

### 6. `X-Email` is not a secret second factor

- **Severity**: Low  
- **Location**: `auth.ex` / `mcp_auth.ex`  
- **Issue**: Email is often known or guessable; control mainly prevents key reuse across emails and forces dual headers. Security still rests almost entirely on the 256-bit key.  
- **Note**: Timing-safe compare is used when lengths match; length mismatch short-circuits (minor timing signal).

### 7. Auth failure timing / enumeration surface

- **Severity**: Low  
- **Location**: `Auth.verify_api_key/2`  
- **Issue**: Invalid hex fails before DB; valid hex + missing key skips email compare; wrong email does compare. Small timing differences may leak “key exists”. Acceptable for high-entropy keys; avoid logging success/failure distinctions that aid targeting.

### 8. CORS always advertises methods/headers

- **Severity**: Low  
- **Location**: `lib/elx_mcp_web/plugs/cors.ex`  
- **Issue**: `Access-Control-Allow-Methods/Headers` are set even when Origin is not allowlisted (only ACAO is conditional). Minor recon aid. Prod correctly refuses `*` unless `allow_cors_star` (false by default).  
- **Positive**: `x-api-key` / `x-email` allowed only for configured origins; no `Allow-Credentials: true`.

### 9. Mix tasks print plaintext keys to stdout

- **Severity**: Low (operational)  
- **Location**: `mix elx_mcp.gen_api_key`, `mix elx_mcp.create_project`  
- **Issue**: Shell history / CI logs can retain secrets. Expected for CLI issuance; warn operators; prefer secret managers for prod.

### 10. No structured auth audit trail

- **Severity**: Low  
- **Location**: Auth / MCPAuth  
- **Issue**: No persistent log of failed auth, revoke, or key use beyond debounced `last_used_at`. Hinders incident response.

### 11. `project:write` scope exists without enforcement surface

- **Severity**: Low  
- **Location**: `Catalog.scopes/0`, verify requires `project:read` only  
- **Issue**: Write scope is unused by tools. Future write tools must re-check `Scope.has_scope?(scope, "project:write")` on every handler — do not rely on mount-time assigns alone.

---

## Positive controls (summary)

Checked and clean enough not to expand: dual-header verify + SHA-256 of 32-byte keys; email normalize + `Plug.Crypto.secure_compare/2`; revoke + soft-delete filter; strip `x-api-key`/`x-email` before Anubis context; all MCP tools/resources use `Helpers.with_scope` / `scope_from_frame` + context `where: project_id == ^…`; LIKE wildcards escaped; prod CORS allowlist + no bare `*`; `SECRET_KEY_BASE` required in prod; `.env` gitignored; force_ssl/HSTS in `prod.exs`.

---

## Recommendations (priority)

1. **P0**: Require verified DB TLS in production (`DB_SSL` + CA).  
2. **P1**: Bind MCP sessions to `api_key_id`/`project_id`; harden session id entropy.  
3. **P1**: Replace ETS rate limiter with atomic, multi-node-aware limiter; trust proxy config.  
4. **P2**: API key expiry + rotation runbook.  
5. **P2**: Stop casting `project_id`; Scope-first write APIs before any write tools.  
6. **P3**: Auth audit events; tighten CORS header emission to allowlisted origins only.

## Tools to run manually

- `mix sobelow --exit medium`  
- `mix deps.audit` / `mix hex.audit`  
- Penetration: cross-tenant tool calls with key A against entity keys from project B (expect not_found)  
- Confirm prod env: `DB_SSL`, `MCP_CORS_ORIGINS`, `SECRET_KEY_BASE`, no `allow_cors_star`
