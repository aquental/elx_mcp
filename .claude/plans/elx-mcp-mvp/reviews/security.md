# Security Audit: ElxMCP API key auth & multi-tenant isolation

## Executive Summary

API key design is largely sound for an MVP: 32-byte CSPRNG material, SHA-256 at rest, project-scoped keys, `X-API-Key` on every MCP request, and read paths filter by `scope.project_id`. **No critical tenant-bypass was found in current read-only MCP tools** when the auth plug assigns propagate into Anubis `frame.assigns` (verified via Anubis `build_request_context` → `merge_transport_assigns`).

Main risks: **API key plaintext lands in Anubis `frame.context.headers`**, **no rate limiting / auth write amplification**, **CORS `*` default outside prod override**, **scopes not allowlisted and not re-checked in tools**, and **write APIs take bare `project_id` without `Scope`**. Fix these before write tools or public exposure.

## Critical / High findings

### WARNING: Plaintext API key copied into Anubis request context
- **Severity**: High
- **Location**: `deps/anubis_mcp/.../streamable_http/plug.ex:714-727` (context build); consumed at `deps/anubis_mcp/.../session.ex:805-833`
- **Issue**: Every authenticated MCP request puts full `conn.req_headers` (including `x-api-key`) into `frame.context.headers`. Secret lives in session process memory and any future dump of `frame.context`, telemetry, or error reporters can leak the live key. Context is rebuilt per request (not session-persisted), but exposure surface remains.
- **Fix**: Prefer not relying on Anubis to scrub; document operational risk; avoid logging `frame`; consider wrapping transport so sensitive headers are stripped before `build_request_context` if Anubis allows customization; never put keys in assigns.
- **OWASP**: A02 Cryptographic Failures / sensitive data exposure

### WARNING: No rate limiting on `/mcp` authentication
- **Severity**: High
- **Location**: `lib/elx_mcp_web/router.ex:17-33`; `lib/elx_mcp_web/plugs/mcp_auth.ex:14-33`; `lib/elx_mcp/auth.ex:39-59`
- **Issue**: Every request (valid or not) hits DB (`fetch_active_key`). Valid keys also `UPDATE api_keys SET last_used_at` (`auth.ex:90-94`). No Hammer/PlugAttack/IP throttle. 256-bit keyspace makes guessing impractical; **DoS via auth + update_all is practical**.
- **Fix**: Rate-limit by IP (and optionally key_prefix) on 401 and overall `/mcp`; debounce `touch_last_used` (e.g. once per N minutes); consider fail2ban at edge.
- **OWASP**: A04 Insecure Design / A05 Security Misconfiguration

### WARNING: Body parsed before API-key auth
- **Severity**: Medium–High
- **Location**: `lib/elx_mcp_web/endpoint.ex:46-54` then router `:mcp` pipeline
- **Issue**: `Plug.Parsers` runs globally before `MCPAuth`. Unauthenticated clients can force JSON parse cost before 401.
- **Fix**: Lower parser length limits on MCP scope, or authenticate in a plug before heavy parsing where feasible; edge body size limits.

### WARNING: CORS allows `*` and advertises `x-api-key`
- **Severity**: Medium (High if prod mis-set)
- **Location**: `config/config.exs:14`; `config/dev.exs` (also `*`); `lib/elx_mcp_web/plugs/cors.ex:17-26`; prod override `config/runtime.exs:44-50`
- **Issue**: Base/dev default is `mcp_cors_origins: ["*"]`, which emits `Access-Control-Allow-Origin: *` and allows header `x-api-key`. Prod correctly defaults to empty list from `MCP_CORS_ORIGINS` (browser CORS denied). If ops set `MCP_CORS_ORIGINS=*`, any origin can call the API from a browser with a stolen/pasted key. Header auth is not cookie CSRF, but `*` is still a footgun for browser-hosted clients.
- **Fix**: Refuse `*` in prod; allowlist exact origins; never combine `*` with credentialed flows; document that Cursor/desktop clients do not need CORS.
- **OWASP**: A05 Security Misconfiguration

### WARNING: Scopes not allowlisted; tools never re-check `has_scope?`
- **Severity**: Medium (High when write tools ship)
- **Location**: `lib/elx_mcp/auth/api_key.ex:26-34`; `lib/elx_mcp/auth.ex:27,44`; `lib/elx_mcp/auth/scope.ex:19-21`; MCP tools under `lib/elx_mcp/mcp/tools/*`
- **Issue**: Changeset casts arbitrary `scopes` with no `validate_subset`. Verify only requires `"project:read" in key.scopes`. Tools use `Helpers.with_scope` only — no per-tool `Scope.has_scope?/2`. Any key with `project:read` (plus junk scopes) gets all tools. Future `project:write` tools will be wide-open unless checks are added.
- **Fix**: Allowlist scopes at create (`~w(project:read project:write)`); re-check required scope in each tool/resource; reject unknown scopes.

### WARNING: `scope_from_frame/1` defaults missing scopes to full read
- **Severity**: Medium
- **Location**: `lib/elx_mcp/mcp/helpers.ex:7-17`
- **Issue**: If `project_id` / `api_key_id` / email are present but `scopes` is missing (partial/stale session assigns, recovery edge case), code injects `["project:read"]` instead of denying.
- **Fix**: Require `scopes` key; return `nil` / unauthorized when absent.

### WARNING: Write/context APIs accept bare `project_id` without `Scope`
- **Severity**: Medium
- **Location**: `lib/elx_mcp/projects.ex` create_* (e.g. 15-18, 49-60, 123-136); `lib/elx_mcp/collaboration.ex:13-17,29-32,61-69`; `lib/elx_mcp/auth.ex:70` `get_api_key!/1`
- **Issue**: Reads correctly take `%Scope{}`. Creates take raw `project_id` and cast associations without same-tenant checks. Safe only while MCP is read-only and callers are trusted (Mix/seeds). Any future tool calling `create_*` with client-influenced IDs risks cross-tenant links (see next).
- **Fix**: Pass `%Scope{}` into all mutations; set `project_id` only from scope; never cast `project_id` from client attrs.

### WARNING: No DB-level same-tenant integrity on associations
- **Severity**: Medium
- **Location**: migration `priv/repo/migrations/20260801200000_create_project_domain.exs` (e.g. user_stories.epic_id, tickets.user_story_id); schemas cast FKs without project match
- **Issue**: FKs ensure target row exists, not that `epic.project_id == story.project_id`. Malicious/buggy writer can link cross-project. `get_epic` + preload could then surface foreign children if data is poisoned.
- **Fix**: Validate association targets share `project_id` in changesets; consider composite FKs / triggers.

## Medium / Low findings

### WARNING: Auth timing & last-used side channel
- **Severity**: Low–Medium
- **Location**: `lib/elx_mcp/auth.ex:39-59,80-94`
- **Issue**: SHA-256 + unique hash lookup is appropriate for 32-byte keys (Argon2 unnecessary). Invalid format fails faster than DB miss; valid keys pay `update_all`. Not practical to brute-force keys; still distinguishable for traffic analysis.
- **Fix**: Optional dummy work on miss; rate limits matter more.

### WARNING: Session assigns carry tenant identity without binding to session store crypto
- **Severity**: Low–Medium
- **Location**: Anubis session serialization (`Frame.to_saved` assigns); `lib/elx_mcp/mcp/server.ex` (no `serialize_assigns/1`)
- **Issue**: `project_id`, `api_key_id`, scopes persisted in session store if configured. HTTP path re-auths and re-merges assigns each request (good). If a code path ever ran tools without fresh transport assigns, stale tenant could apply. Server does not implement `serialize_assigns` to minimize persisted secrets.
- **Fix**: Implement `serialize_assigns/1` to store only non-sensitive ids; re-resolve scope from DB on recovery; bind session to `api_key_id` and reject key mismatch.

### SUGGESTION: Mix gen task & seeds print plaintext key
- **Severity**: Low (expected once)
- **Location**: `lib/mix/tasks/elx_mcp.gen_api_key.ex:43-49`; `priv/repo/seeds.exs:145-150`
- **Issue**: Intentional one-time reveal. Risk is shell history / CI logs.
- **Fix**: Document; avoid running gen in shared CI logs; support writing to a file with 0600 perms.

### SUGGESTION: Mix task uses `app.config` + `ensure_all_started` (good)
- **Severity**: Info / positive
- **Location**: `lib/mix/tasks/elx_mcp.gen_api_key.ex:31-32`
- **Notes**: Correctly avoids `app.start` full endpoint boot pattern.

### SUGGESTION: No API key expiry / rotation metadata
- **Severity**: Low
- **Location**: `lib/elx_mcp/auth/api_key.ex` schema
- **Fix**: Add `expires_at`; reject expired in `verify_api_key/1`; rotation runbook.

### SUGGESTION: Prod Repo SSL commented out
- **Severity**: Medium (env-dependent)
- **Location**: `config/runtime.exs:61-62`
- **Issue**: `# ssl: true` disabled — DB traffic may be cleartext on the network.
- **Fix**: Enable SSL/TLS to Postgres in production.

### SUGGESTION: SSE subscriber metadata not tenant-tagged
- **Severity**: Low (future)
- **Location**: router forward to StreamableHTTP.Plug without `:subscriber_metadata`
- **Issue**: Default metadata `%{}` — future broadcasts cannot filter by `project_id`.
- **Fix**: Pass `&…/1` that returns `%{project_id: conn.assigns.project_id}`.

## Security posture (focused)

### Authentication
- Status: ⚠️ solid core, operational gaps
- Notes: 32-byte key, hex validation (`auth.ex:80`), SHA-256 storage, revoke via `revoked_at`, Mix task safe boot. Gaps: rate limit, last_used write amp, key-in-headers context, no expiry.

### Authorization / tenant isolation
- Status: ⚠️ good on read path
- Notes: MCP tools/resources use `Helpers.with_scope` + `Projects.*(%Scope{}, …)` with `where: project_id == ^project_id`. Assigns: `MCPAuth` → `conn.assigns` → Anubis context `:assigns` → `frame.assigns`. Mutations and FK integrity not Scope-hard yet.

### Input validation
- Status: ⚠️
- Notes: Tool schemas constrain limits; search escapes LIKE wildcards (`projects.ex:315-320`) and keeps project filter. Scopes/metadata maps under-validated.

### SQL injection
- Status: ✅
- Notes: Parameterized Ecto (`^`); no string-interpolated fragments found in app lib.

### XSS / CSRF
- Status: ✅ for MCP API
- Notes: JSON MCP; browser pipeline has CSRF/forgery protection. CORS is the browser-relevant control for `/mcp`.

### Secrets management
- Status: ⚠️
- Notes: Prod `SECRET_KEY_BASE` / `DATABASE_URL` from env. API keys hashed. Plaintext key only at generation. Risk: key in Anubis headers context; no `filter_parameters` impact (header-based).

### CSRF / CORS
- Status: ⚠️
- Notes: Prod empty allowlist by default is safe; `*` in non-prod and possible prod misconfig.

## Positive controls (do not regress)

| Control | Where |
|--------|--------|
| CSPRNG 32-byte key + hex encode | `auth.ex:14-15` |
| Store SHA-256 only | `auth.ex:17,26` |
| Project forced on create (merge wins) | `auth.ex:21-28` |
| Auth on every MCP request (not session-only) | `router.ex:17-21`, `mcp_auth.ex` |
| OPTIONS skip + CORS halt before auth | `cors.ex:37-40`, `mcp_auth.ex:12` |
| Tenant filter on lists/gets/search | `projects.ex`, `collaboration.ex` |
| Read tools require frame scope | `helpers.ex:24-31` |
| Prod CORS from env, default deny | `runtime.exs:44-50` |
| Mix: `app.config` not `app.start` | `gen_api_key.ex:31-32` |

## Recommendations (priority)

1. **P0**: Rate-limit `/mcp` + throttle/debounce `touch_last_used`.
2. **P0**: Treat `frame.context.headers["x-api-key"]` as secret; ban logging frames/context; scrub if possible.
3. **P1**: Allowlist scopes; require scopes in `scope_from_frame`; plan `has_scope?` on every tool.
4. **P1**: Refuse CORS `*` in prod; keep empty default.
5. **P1**: Scope all mutations; validate association `project_id` match before write tools.
6. **P2**: Key expiry/rotation; tenant SSE metadata; enable DB SSL; body size limits pre-auth.
7. **P2**: Implement Anubis `serialize_assigns/1` to avoid persisting extra secrets.

## Tools to run manually

```bash
mix sobelow --exit medium
mix deps.audit
mix hex.audit
```

## Verdict

**No BLOCKER tenant escape found on current read-only MCP surface** given re-auth per request and scoped queries. **Do not ship public multi-tenant production** until rate limiting, CORS prod hardening, header/secret handling, and Scope-based writes are addressed. Write-tool milestone must treat scopes + association tenancy as blockers.
