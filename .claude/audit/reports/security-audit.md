# Security Audit: ElxMCP (post-P1 residual remediation)

**Date:** 2026-08-02  
**Score:** **89 / 100**  
**Scope:** `lib/elx_mcp/auth/**`, `lib/elx_mcp_web/plugs/mcp_auth.ex`, scope-first writes / `authorize_write`, schema casts, SessionBind, RateLimit, secrets/`String.to_atom`/`raw/`  
**Auth model:** dual-header `X-API-Key` + `X-Email`, SHA-256 key hash, multi-tenant `%Scope{}`, MCP via Anubis streamable HTTP  

## Executive Summary

Prior **P1** findings are **fixed**: RateLimit ETS is Application-owned and fail-closed; SessionBind enforces principal ownership on MCP lifecycle (fail-closed on unbound GET/DELETE); write contexts require `project:write` and set tenant/actor fields via `put_change` (not cast). No critical SQLi/RCE/XSS/atom-DoS found. Residual risk is **P2/P3** operational hygiene (key expiry, single-node rate limit + proxy IP, DB SSL opt-out, latent attachment mass-assign fields). `mix sobelow` is **not installed**.

## Score breakdown

| Bucket | Max | Awarded | Notes |
|--------|----:|--------:|-------|
| sobelow / critical manual | 30 | 28 | No criticals on manual grep; sobelow **not** in deps (−2 for scan gap) |
| high residual | 20 | 16 | P1s fixed; residual: single-node/IP rate limit, no key expiry, DB SSL opt-out |
| authz handle_event | 15 | 14 | N/A LiveView; MCP tools `with_scope` + context `authorize_write` |
| `to_atom` | 10 | 10 | None in `lib/` |
| `raw` / XSS | 10 | 10 | None in `lib/` |
| secrets | 15 | 11 | Prod `SECRET_KEY_BASE` required; DB SSL disableable; no explicit `filter_parameters` |
| **Total** | **100** | **89** | Grade **A−** |

## Fixed P1s (do not re-open)

| Former P1 | Status | Evidence |
|-----------|--------|----------|
| Rate-limit ETS owned by request process | **Fixed** | `Application.start/2` → `RateLimit.setup!/0`; `require_table!/0` raises if missing (never creates from request) |
| MCP session not bound to principal | **Fixed** | `SessionBind` + `MCPAuth.enforce_session_bind/2`: POST `bind_if_new`, GET/DELETE `verify_owner` fail-closed; DELETE unbinds |
| Latent `project_id` cast / no `project:write` | **Fixed** | Schemas omit `:project_id` from cast; `Auth.authorize_write/1` on all `Projects`/`Collaboration` writes; actor fields via `put_change` |

## Critical / High

*None remaining in scoped code.*

## Residual issues (P2/P3 only)

### P2 — API keys never expire
- **Severity:** Medium  
- **Location:** `lib/elx_mcp/auth/api_key.ex`, `lib/elx_mcp/auth.ex` `fetch_active_key/1` (`is_nil(k.revoked_at)` only)  
- **Issue:** Compromised keys stay valid until manual revoke. No `expires_at` / rotation SLA.  
- **Fix:** Add nullable `expires_at`; filter in `fetch_active_key/1`; document rotate + revoke via mix tasks.  
- **OWASP:** A07  

### P2 — Rate limit still single-node, IP-only, proxy-blind
- **Severity:** Medium (abuse / DoS posture; not auth bypass)  
- **Location:** `lib/elx_mcp/auth/rate_limit.ex`, `lib/elx_mcp_web/plugs/mcp_auth.ex:22-27`  
- **Issue:** ETS counters work correctly now (Application-owned), but: (1) not multi-node-safe; (2) keyed only by `conn.remote_ip` pre-auth (not post-auth `api_key_id`); (3) no trusted-proxy / `x-forwarded-for` — behind LB all clients may share one IP or spoof if proxy headers trusted incorrectly later.  
- **Fix:** Document Redis/Hammer for multi-node; dual-key IP + `api_key_id` after auth; configure Bandit/Plug remote IP from trusted hop only.  

### P2 — Prod DB TLS still operator-disableable
- **Severity:** Medium (operator misconfig)  
- **Location:** `config/runtime.exs` `DB_SSL` (`false` allowed; `verify_none` only warns in prod)  
- **Issue:** Default prod is SSL on; `DB_SSL=false` silently disables TLS; `verify_none` does not hard-fail.  
- **Fix:** Hard-fail insecure flags in prod unless explicit `ALLOW_INSECURE_DB_SSL=1`; prefer `verify: :verify_peer` + CA path.  

### P2 — Attachment mass-assign residual (`storage_path`, `uploaded_by_email`)
- **Severity:** Medium (latent; no MCP write tool yet for attachments)  
- **Location:** `lib/elx_mcp/collaboration/attachment.ex:28-36`; mitigated partially in `Collaboration.create_attachment/2` via `put_change(:uploaded_by_email, …)`  
- **Issue:** Changeset still casts `:storage_path` and `:uploaded_by_email`. Actor email is overwritten by context; `storage_path` remains client-influenced metadata. Dangerous if a future download path uses it without `Path.safe_relative/2`.  
- **Fix:** Drop both from cast; set path/actor only in context from trusted storage layer.  

### P3 — SessionBind legacy 2-tuple never expires
- **Location:** `lib/elx_mcp/auth/session_bind.ex:119-121`  
- **Issue:** Pre-TTL entries `{sid, {key, proj}}` skip TTL prune forever until process restart. Harmless after clean deploy if table recreated; residual for hot upgrades that preserve ETS.  
- **Fix:** Treat legacy as expired or rebind with timestamp on first touch.  

### P3 — Auth timing / email as weak second factor
- **Location:** `lib/elx_mcp/auth.ex` `verify_api_key/2`  
- **Issue:** Invalid hex fails before DB; missing key skips email compare; length-mismatched emails short-circuit before `secure_compare`. Acceptable given 256-bit key entropy; email is not secret.  

### P3 — CORS always advertises methods/headers
- **Location:** `lib/elx_mcp_web/plugs/cors.ex:14-21`  
- **Issue:** `Allow-Methods/Headers` set even when Origin not allowlisted; only `Allow-Origin` is gated. Star still requires `allow_cors_star` (dev/test only).  

### P3 — No structured auth audit trail
- **Issue:** No persistent failed-auth / revoke / session-forbidden events beyond debounced `last_used_at`.  

### P3 — Mix tasks print plaintext API keys to stdout
- **Location:** `mix elx_mcp.gen_api_key`, `mix elx_mcp.create_project`  
- **Issue:** Shell history / CI logs can retain secrets (expected for CLI issuance; still worth warning).  

### P3 — Browser session cookie not prod-hardened
- **Location:** `lib/elx_mcp_web/endpoint.ex` `@session_options`  
- **Issue:** No explicit `secure: true` (MCP is header-auth; low impact).  

### P3 — `mix sobelow` not in project
- **Issue:** No automated static security gate in CI.  

## Security Posture (issues only)

Checked dual-header verify, SHA-256 hash-at-rest, secure email compare (equal length), header scrub of key/email, SessionBind fail-closed lifecycle, RateLimit Application ownership, `authorize_write` + tenant `put_change`, MCP `with_scope` + `project_id == ^`, schema casts (no `project_id`/`key` mass-assign on work items), `String.to_atom`/`raw`/SQL interpolation, prod secrets env: **clean except residuals above**.

## Auth plug / write-path trace

| Check | Result |
|-------|--------|
| Rate limit before auth | ✅ Application-owned ETS |
| Both headers required | ✅ |
| Active + not revoked key | ✅ |
| `project:read` required for session | ✅ |
| POST session bind / GET·DELETE owner verify | ✅ fail-closed |
| Context writes require `project:write` | ✅ |
| Entity FKs checked same `project_id` | ✅ `ensure_same_project` / `ensure_entity_in_project` |

## Recommendations (priority)

1. **P2:** Key `expires_at` + rotation runbook.  
2. **P2:** Multi-node rate limit + trusted proxy IP + optional per-key limit.  
3. **P2:** Hard-fail insecure `DB_SSL` in prod.  
4. **P2:** Stop casting attachment `storage_path` / `uploaded_by_email`.  
5. **P3:** Auth failure telemetry; sobelow in CI; expire legacy SessionBind tuples; `secure` cookie for any future browser auth.  

## Tools to run manually

- `mix sobelow --exit medium` (add `:sobelow` first)  
- `mix deps.audit` / `mix hex.audit`  
- Cross-tenant: key A + entity keys from project B → not_found  
- Session: key B + `mcp-session-id` bound to key A → 403 on POST/GET/DELETE  
- Rate limit: exceed limit across two TCP connections (table must persist)  
- Prod env: `SECRET_KEY_BASE`, `DB_SSL`, `MCP_CORS_ORIGINS`, no `allow_cors_star`  
