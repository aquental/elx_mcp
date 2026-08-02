# Security Audit: ElxMCP

**Date:** 2026-08-02  
**Scope:** auth, plugs (MCPAuth/CORS), RLS/`with_tenant`, MCP tools/resources, runtime secrets, RLS migrations, `spec/DB_SEC.md`, `.gitignore`  
**Auth model:** dual-header `X-API-Key` + `X-Email`, SHA-256 key hash, `%Scope{}`, Anubis streamable HTTP on `/mcp`  
**Static scan:** `mix sobelow` **not** in `mix.exs` deps (not run)

## Executive Summary

Application-layer auth for MCP is solid: dual-header verify, rate limit (Application-owned ETS, fail-closed), SessionBind on lifecycle methods, header scrub of secrets, scope-first writes with `authorize_write`, FORCE RLS + `SET LOCAL` tenant GUC, parameterized Ecto queries, no `String.to_atom` / `raw` / SQL interpolation in `lib/`. No **P1** app bugs found in scoped code.

Residual risk is **P2/P3** (key lifetime, GUC-based RLS not binding the DB role, single-node rate limit, operator SSL opt-out, attachment cast) plus **open infra items from DB_SEC** (public Postgres / weak role / git history secrets).

## Score breakdown

| Bucket | Max | Awarded | Notes |
|--------|----:|--------:|-------|
| sobelow / critical manual | 30 | 28 | No criticals on manual grep; sobelow absent (−2) |
| high residual | 20 | 15 | GUC bypass residual; single-node RL; no key expiry; DB SSL opt-out |
| authz (events / MCP tools) | 15 | 14 | All tools `with_scope` + context `tenant`; writes need `project:write` |
| `to_atom` | 10 | 10 | None in `lib/` |
| `raw` / XSS | 10 | 10 | None in `lib/` |
| secrets | 15 | 11 | Prod `SECRET_KEY_BASE` required; DB SSL disableable; no `filter_parameters` |
| **Total** | **100** | **88** | Grade **A−** |

---

## P1 — Critical / High (app code)

*None in scoped application code.*

Checked clean: dual-header verify + SHA-256, `secure_compare` email (equal length), revoked filter in secdef lookup, MCP pipeline on all `/mcp`, SessionBind fail-closed GET/DELETE, RateLimit Application ownership, `authorize_write` + `put_change` for tenant/actor fields, `^` pins / `escape_like` for ILIKE, FORCE RLS + `with_tenant` clear GUC, prod `force_ssl`, CORS star gated by `allow_cors_star`, `.env` / `.env.gpg` gitignored.

---

## P2 — Medium

### P2 — `app.bypass_rls` is a client-settable GUC (RLS not binding to the DB role)
- **Location:** `priv/repo/migrations/20260802170100_secdef_row_security_off.exs` (policies + secdef `set_config`); `lib/elx_mcp/repo.ex` (sets `off` in `with_tenant`)
- **Issue:** Policies honor `current_setting('app.bypass_rls') = 'on'`. Any session that can run SQL as the app role can `SELECT set_config('app.bypass_rls','on',true)` and read/write all tenants. Secdef helpers also set LOCAL bypass for the ambient transaction (Sandbox / outer `Repo.transaction`). RLS is **defense-in-depth against missing `with_tenant`**, not against a stolen DB password.
- **Fix:** Treat DB credentials as full-data access; least-privilege role + network isolation (DB_SEC). Optionally move bypass to a non-GUC path (superuser-only secdef owner, or separate migrator role). Document that app role compromise = full dump.
- **OWASP:** A01 / A04

### P2 — API keys never expire
- **Location:** `lib/elx_mcp/auth/api_key.ex`; `lib/elx_mcp/auth.ex` `fetch_active_key/1` (secdef: `revoked_at IS NULL` only)
- **Issue:** Compromised keys remain valid until manual revoke. No `expires_at` / rotation SLA.
- **Fix:** Add nullable `expires_at`; filter in `elx_mcp_lookup_api_key`; document rotate + revoke mix tasks.
- **OWASP:** A07

### P2 — Rate limit single-node, IP-only, proxy-blind
- **Location:** `lib/elx_mcp/auth/rate_limit.ex`; `lib/elx_mcp_web/plugs/mcp_auth.ex` (~L22–27)
- **Issue:** ETS is Application-owned (good) but (1) not multi-node-safe; (2) keyed only by `conn.remote_ip` pre-auth; (3) no trusted-proxy hop — behind LB all clients may share one IP (or spoof if XFF trusted wrongly later).
- **Fix:** Redis/Hammer for multi-node; dual-key IP + `api_key_id` post-auth; configure Bandit/Plug remote IP from trusted hop only.

### P2 — Prod DB TLS operator-disableable
- **Location:** `config/runtime.exs` (`DB_SSL=false` allowed; `verify_none` only warns in prod)
- **Issue:** Default SSL-on is good; misconfig can silently disable TLS or skip cert verify.
- **Fix:** Hard-fail insecure flags in prod unless `ALLOW_INSECURE_DB_SSL=1`.

### P2 — Attachment mass-assign residual (`storage_path`, `uploaded_by_email`)
- **Location:** `lib/elx_mcp/collaboration/attachment.ex` cast list; partially mitigated in `Collaboration.create_attachment/2` via `put_change(:uploaded_by_email, …)`
- **Issue:** Changeset still casts `:storage_path` and `:uploaded_by_email`. Actor email is overwritten; `storage_path` remains client-influenced. Latent path traversal if a future download uses it without `Path.safe_relative/2`. No MCP write tool for attachments yet.
- **Fix:** Drop both from cast; set path/actor only in context from trusted storage.

### P2 — SECURITY DEFINER `EXECUTE` granted to `PUBLIC`
- **Location:** `priv/repo/migrations/20260802170000_rls_harden_local_guc_secdef.exs` (~L249–250); functions recreated in `…70100…` (privileges retained)
- **Issue:** Any DB role with `CONNECT` can call `elx_mcp_list_projects()`, `elx_mcp_get_api_key(uuid)`, etc., bypassing RLS for those lookups. Acceptable for single app-owner role; risky on multi-role clusters.
- **Fix:** `REVOKE EXECUTE … FROM PUBLIC; GRANT EXECUTE … TO elx_mcp_app` only.

---

## P3 — Low

### P3 — Nested `with_tenant` overwrites GUC without restore
- **Location:** `lib/elx_mcp/repo.ex` depth > 0 branch
- **Issue:** Nested call with a different `project_id` leaves outer scope on the nested GUC. Current MCP path nests same ID only.
- **Fix:** Save/restore previous GUC on nested exit, or refuse nested different tenants.

### P3 — SessionBind legacy 2-tuple never expires
- **Location:** `lib/elx_mcp/auth/session_bind.ex` (~L119–121)
- **Issue:** Pre-TTL entries skip prune until process restart.
- **Fix:** Treat legacy as expired or rebind with timestamp.

### P3 — Auth timing / email as weak second factor
- **Location:** `lib/elx_mcp/auth.ex` `verify_api_key/2`
- **Issue:** Invalid hex fails before DB; missing key skips email compare; length mismatch skips `secure_compare`. Acceptable given 256-bit key entropy; email is not secret.

### P3 — CORS always advertises methods/headers
- **Location:** `lib/elx_mcp_web/plugs/cors.ex` (~L14–21)
- **Issue:** `Allow-Methods/Headers` set even when Origin not allowlisted; only `Allow-Origin` gated. Star still requires `allow_cors_star`.

### P3 — No structured auth audit trail
- **Issue:** No persistent failed-auth / revoke / session-forbidden events beyond debounced `last_used_at`.

### P3 — Mix tasks print plaintext API keys to stdout
- **Location:** `mix elx_mcp.gen_api_key`, `mix elx_mcp.create_project`
- **Issue:** Shell history / CI logs can retain secrets (expected for CLI issuance).

### P3 — Browser session cookie not prod-hardened
- **Location:** `lib/elx_mcp_web/endpoint.ex` `@session_options`
- **Issue:** No explicit `secure: true` / `http_only` (Plug defaults `http_only: true`). MCP is header-auth; low impact. Prod has `force_ssl`.

### P3 — No `filter_parameters` for sensitive keys
- **Location:** endpoint / logger config
- **Issue:** Headers scrubbed in MCPAuth; if keys ever land in params/logs, no Phoenix filter. Low today.

### P3 — `mix sobelow` not in project / CI
- **Issue:** No automated static security gate.

### P3 — Committed dev/test `secret_key_base`
- **Location:** `config/dev.exs`, `config/test.exs`
- **Issue:** Phoenix default; must never be reused in prod (prod requires env).

---

## Residual infra risks (from `spec/DB_SEC.md` — still open / operational)

These are **not** fixed by app code; they dominate real breach risk if true on the host:

| ID | Risk | Status (per DB_SEC) |
| -- | ---- | ------------------- |
| C1 | Postgres `listen_addresses=*` / public `:5432` | Open unless host remediated |
| C2 | Weak DB password (user==password patterns) | Open unless rotated |
| C3 | App role `CONNECT` on unrelated databases | Open unless REVOKE |
| A1 | Role with `CREATEROLE` / `CREATEDB` excess | Open unless hardened |
| A2 | Historical `DB_SSL=verify_none` | App defaults better now; operator can still disable |
| M1 | `.env.gpg` may remain in **git history** | Tree cleaned; rotate if repo was/is shared |

**Implication:** Compromised DB credentials bypass MCP auth, API keys, and RLS GUCs entirely.

---

## Recommendations (priority)

1. **Ops:** Close public Postgres, rotate passwords, `NOCREATEROLE`, revoke multi-DB CONNECT, verify TLS peer (DB_SEC §5).
2. **App:** API key `expires_at` + rotation docs.
3. **App:** Restrict secdef `EXECUTE` to app role; document GUC-bypass residual.
4. **App:** Drop `storage_path` / `uploaded_by_email` from attachment cast.
5. **App:** Hard-fail insecure `DB_SSL` in prod; multi-node rate limit when scaling.
6. **CI:** Add `sobelow` + `deps.audit` to precommit/CI.

## Tools to run manually

```bash
mix sobelow --exit medium   # after adding {:sobelow, only: [:dev, :test], runtime: false}
mix deps.audit
mix hex.audit
```

---

SCORE: 88
