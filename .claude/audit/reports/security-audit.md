# Security Audit — ElxMCP
**Date:** 2026-08-02  
**Score:** 80  
**Scope:** `lib/elx_mcp/auth*`, `plugs/`, `mcp/`, `config/*`, secrets hygiene  
**Auth model:** dual-header `X-API-Key` + `X-Email`, SHA-256 of 32-byte keys, multi-tenant `Scope`, MCP via `anubis_mcp`

## Summary

Core dual-header authentication and read-path tenant isolation remain **sound**. Every MCP tool/resource resolves scope from frame assigns and queries with `project_id == ^…`. No `String.to_atom/1`, no `raw/1`, no SQL interpolation. Secrets load from env in prod; `.env` is gitignored.

Score drops vs a hardened 90+ posture primarily because: **(1)** ETS rate-limit table is owned by the request process that first creates it (not Application), so counters do not reliably survive across connections; **(2)** MCP sessions are not bound to `api_key_id` (DELETE/SSE lifecycle keyed only by client-supplied `mcp-session-id`); **(3)** latent `project_id` mass-assignment on write schemas; **(4)** keys never expire; **(5)** no `mix sobelow` in the project.

`mix sobelow` is **not available** (not in `mix.exs` deps). Manual greps substituted.

## Score breakdown

| Bucket | Max | Awarded | Notes |
|--------|----:|--------:|-------|
| sobelow / critical manual | 30 | 30 | No critical SQLi / RCE / XSS / atom DoS found |
| high residual | 20 | 8 | Rate-limit ETS ownership; session not bound to key |
| authz (tools / events) | 15 | 12 | Reads scoped; write dual-API / cast latent |
| `to_atom` | 10 | 10 | None in `lib/` |
| `raw` / XSS | 10 | 10 | None in `lib/` |
| secrets | 15 | 10 | Prod env OK; DB SSL operator-misconfig; no filter_parameters |
| **Total** | **100** | **80** | Grade **B** |

## Issues found

### P1

#### 1. Rate-limit ETS table not supervised — effectively per-connection
- **Location:** `lib/elx_mcp/auth/rate_limit.ex:12-28`, `lib/elx_mcp_web/plugs/mcp_auth.ex:20`
- **Issue:** `setup!/0` creates a **named public ETS table owned by the calling process**. Only callers are `check/2` and `reset!/0` (tests). Not started from `ElxMcp.Application`. When the HTTP connection process that first created the table exits, the table is **deleted**. Counters do not accumulate across independent connections; abuse protection is largely ineffective in production. Atomic `update_counter/4` is correct **within** a live table, but table lifetime is wrong.
- **Also:** IP-only key (`"mcp:" <> remote_ip`), single-node, no prune of old `{key,bucket}` rows, no trusted-proxy / `x-forwarded-for` handling.
- **Fix:** Create table once in Application (or dedicated GenServer owner with heir); prune stale buckets; key by IP pre-auth + `api_key_id` post-auth; multi-node → Redis/Hammer; configure remote IP behind LB.

#### 2. MCP sessions not bound to `api_key_id` / project
- **Location:** `lib/elx_mcp_web/plugs/mcp_auth.ex` (auth only); Anubis `StreamableHTTP.Plug` `handle_delete/2` (~452), `get_or_create_session_id/2` (~595), `merge_transport_assigns/2` in `session.ex` (~836)
- **Issue:** Every POST re-auths and `merge_transport_assigns` overwrites frame assigns from `conn.assigns` — **tool data stays tenant-correct**. However session lifecycle (SSE register, restore, **DELETE**) is keyed only by `mcp-session-id`. Any authenticated principal who knows/guesses a session id can terminate another client’s session or attach SSE. Clients may supply their own session header on initialize. Anubis IDs use **24-bit pure random** + timestamp + phash2 (~48 bits practical entropy), not ≥128-bit.
- **OWASP:** A01 / A07  
- **Fix:** Bind session → `{api_key_id, project_id}` at create; reject DELETE/SSE on mismatch; prefer high-entropy session ids if customizing transport.

### P2

#### 3. API keys never expire
- **Location:** `lib/elx_mcp/auth/api_key.ex`, `lib/elx_mcp/auth.ex:111-116` (only `is_nil(revoked_at)`)
- **Issue:** Compromised keys remain valid until manual revoke. No `expires_at` / rotation SLA.
- **Fix:** Nullable `expires_at`; filter in `fetch_active_key/1`; rotate via `mix elx_mcp.gen_api_key` + revoke.

#### 4. Latent tenant write hazard — schemas cast `:project_id`
- **Location:**  
  - `lib/elx_mcp/projects/{board,component,sprint,epic,user_story}.ex` (cast includes `:project_id`)  
  - `lib/elx_mcp/collaboration/{comment,attachment,worklog,changelog}.ex`  
  - Contexts: `create_*` take bare `project_id` not `%Scope{}` (`projects.ex:15+`, `collaboration.ex:13+`)  
  - Ticket correctly uses `put_change` only (`ticket.ex:59`)
- **Issue:** Contexts currently `Map.put(:project_id, …)` so atom key wins today. No MCP write tools yet. Future `project:write` tools that pass client attrs risk mass-assignment IDOR.
- **Fix:** Never cast `:project_id`/`:key`; set only via `put_change/3` from `%Scope{}`; prefer `create_*(%Scope{}, attrs)`.

#### 5. Prod DB TLS operator-misconfigurable
- **Location:** `config/runtime.exs:71-94`
- **Issue:** Default in prod is good (`DB_SSL` default `"true"`). Still allows `DB_SSL=false` without warning; `verify_none` only warns. `ssl: true` alone may not set explicit `verify: :verify_peer` + CA path on all platforms.
- **Fix:** Hard-fail insecure flags in prod unless explicit opt-in env; document CA bundle.

#### 6. `project:write` scope unused / not re-checked on future writes
- **Location:** `lib/elx_mcp/catalog.ex:13`, `auth.ex:58` (requires only `project:read`)
- **Issue:** Write scope exists in catalog but is never enforced. When write tools land, each handler must `Scope.has_scope?(scope, "project:write")`.

### P3

#### 7. Auth timing surface + email as non-secret factor
- **Location:** `lib/elx_mcp/auth.ex:49-88`
- **Issue:** Invalid hex fails before DB; missing key skips email compare. Length-mismatched emails short-circuit before `secure_compare`. Email is guessable; security rests on 256-bit key (acceptable).

#### 8. CORS advertises methods/headers even when Origin not allowlisted
- **Location:** `lib/elx_mcp_web/plugs/cors.ex:14-21`
- **Issue:** `Allow-Methods/Headers` always set; only `Allow-Origin` is conditional. Prod refuses `*` unless `allow_cors_star` (false by default). No `Allow-Credentials`.

#### 9. Mix tasks print plaintext keys to stdout
- **Location:** `lib/mix/tasks/elx_mcp.gen_api_key.ex`, `lib/mix/tasks/elx_mcp.create_project.ex`
- **Issue:** Shell history / CI logs can retain secrets (expected for CLI issuance).

#### 10. No structured auth audit trail
- **Location:** Auth / MCPAuth  
- **Issue:** No persistent failed-auth / revoke events beyond debounced `last_used_at`.

#### 11. Anubis context still carries remaining `req_headers`
- **Location:** Anubis `build_request_context` after MCPAuth scrub  
- **Issue:** Key/email headers deleted before forward (good). Avoid logging `frame.context` / headers in prod.

#### 12. Browser session cookie not production-hardened (low impact for MCP)
- **Location:** `lib/elx_mcp_web/endpoint.ex:7-12`  
- **Issue:** Cookie session lacks explicit `secure: true` / `http_only: true` (http_only is Plug default true). MCP auth is header-based, not cookie-based.

#### 13. ILIKE escape without explicit SQL `ESCAPE`
- **Location:** `lib/elx_mcp/projects.ex:246-283`, `escape_like/1:427-432`  
- **Issue:** Pattern is parameterized (`^pattern`) — no SQLi. Wildcard escape relies on PG default `\`; within-tenant over-match only if escape ineffective. Not cross-tenant.

#### 14. `mix sobelow` not in project
- **Issue:** Cannot automate static security scan in CI. Recommend adding `:sobelow` and running `mix sobelow --exit medium`.

## Clean areas (one line)

Dual-header verify + SHA-256 hash-at-rest + `Plug.Crypto.secure_compare` email; header scrub of key/email; all MCP tools/resources use `with_scope`/`scope_from_frame` + `project_id == ^`; no `String.to_atom`/`raw`/interpolated SQL; prod `SECRET_KEY_BASE` required; `.env` gitignored; CORS star gated to dev; Ticket `project_id` not cast; force_ssl in prod.exs.

## Auth plug trace (verification)

| Check | Result |
|-------|--------|
| Both `X-API-Key` + `X-Email` required | ✅ `mcp_auth.ex:34-37` → `verify_api_key/2` |
| Hex format 64 chars | ✅ `valid_hex_key?/1` |
| SHA-256 of raw 32 bytes | ✅ `create` + `verify` |
| Lookup active + not revoked | ✅ `fetch_active_key/1` |
| Email normalize + constant-time when lengths match | ✅ |
| Requires `project:read` in scopes | ✅ |
| Assigns scope, deletes secret headers | ✅ |
| Rate limit before auth | ⚠️ present but ETS owner broken (P1) |

## Tenant isolation (MCP)

All tools under `lib/elx_mcp/mcp/tools/*` and resources under `resources/*` call `Helpers.with_scope` / `scope_from_frame` then `Projects.*` / `Collaboration.*` with `%Scope{}`. List/get/search filter `project_id == ^project_id`. No client-supplied `project_id` on read path.

## Tools to run manually

- `mix sobelow --exit medium` (add dep first)
- `mix deps.audit` / `mix hex.audit`
- Cross-tenant: key A + entity keys from project B → expect not_found
- Confirm prod env: `DB_SSL`, `MCP_CORS_ORIGINS`, `SECRET_KEY_BASE`, no `allow_cors_star`
- Prove rate-limit across two separate TCP connections (expect failure today if ETS dies with first conn)

## Recommendations (priority)

1. **P1:** Own rate-limit ETS from Application; then multi-node + trusted proxy.  
2. **P1:** Bind MCP sessions to `api_key_id`/`project_id`; harden session id entropy.  
3. **P2:** Key expiry + rotation runbook.  
4. **P2:** Stop casting `project_id` on all schemas before any write tools.  
5. **P2:** Harden prod DB SSL flags.  
6. **P3:** Auth audit events; CORS allow-* only for allowlisted origins; add sobelow to CI.
