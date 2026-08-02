# Security Audit: ElxMCP P1 residual (auth / session / scope)

**Scope**: NEW Path A SessionBind, MCPAuth session guard, RateLimit Application ownership, `authorize_write` + Scope writes, schema cast lists (no `project_id`).  
**Date**: 2026-08-02  
**Focus**: IDOR, session hijack residual, races, mass assignment, mutation authz, rate-limit bypass, atom safety, info leakage.

## Executive Summary

P1 residual work **materially improves** posture: Application-owned ETS for rate limit + session bind, POST first-binder ownership, DELETE/GET ownership checks, mutations gated by `project:write`, and `project_id`/`key` no longer mass-assignable. Tool data paths re-auth every request (MCP tools remain read-only).

**No BLOCKER** that re-opens cross-tenant data reads/writes under the current tool surface. Residual risks are **lifecycle/DoS**, **collab integrity**, and **production rate-limit keying**.

Checked: atom safety, SQL pin usage, CSRF (MCP API-key, not cookie session), secrets in runtime.exs for prod — clean for this delta.

---

## BLOCKER

_None in NEW code for cross-tenant data access._

---

## WARNING

### W1 — Unbound session verify is open (pre-bind lifecycle window)

- **Severity**: Medium  
- **Location**: `lib/elx_mcp/auth/session_bind.ex:75-76`, `lib/elx_mcp_web/plugs/mcp_auth.ex:68-82`  
- **Issue**: `verify/3` returns `:ok` when the session is absent. Any authenticated principal who knows a session id **before the first binding POST** can DELETE/GET SSE and disrupt that session. After bind, foreign principals correctly get 403.  
- **Impact**: Session lifecycle DoS / SSE disruption — **not** tool data IDOR (tools re-auth).  
- **Fix**: Prefer fail-closed for DELETE/GET when unbound (`{:error, :forbidden}` or `:not_found`), and bind on the same response that issues `mcp-session-id` (or bind on initialize path). At minimum document the pre-bind window (README already notes private network).  
- **OWASP**: A01 Broken Access Control (session lifecycle).

### W2 — SessionBind ETS has no TTL / size cap (memory DoS)

- **Severity**: Medium  
- **Location**: `lib/elx_mcp/auth/session_bind.ex` (no prune/unbind except DELETE)  
- **Issue**: Each distinct `mcp-session-id` on POST inserts forever. Rate limit (120/min/IP) slows but does not cap growth; multi-IP or long-lived traffic fills ETS.  
- **Fix**: TTL on bind (e.g. store `{owner, bound_at}`, prune stale), max table size, or unbind when Anubis session closes.  
- **OWASP**: A04 Insecure Design / availability.

### W3 — Rate limit keyed only on `conn.remote_ip` (proxy / shared-NAT)

- **Severity**: Medium (prod-behind-proxy)  
- **Location**: `lib/elx_mcp_web/plugs/mcp_auth.ex:22-27`, `lib/elx_mcp/auth/rate_limit.ex:43-60`  
- **Issue**: No `RemoteIp` / trusted-proxy config. Behind a LB, all clients share one IP → global 429 or single bucket. Without trusted hop config, clients cannot spoof easily, but **effective limit is broken** for multi-tenant prod. No per-`api_key_id` limiter post-auth (accepted out of scope).  
- **Fix**: Configure remote IP from trusted `X-Forwarded-For` / `Fly-Client-IP`; add optional post-auth key bucket. Multi-node still needs Redis/Hammer (documented).  
- **OWASP**: A05 Security Misconfiguration / rate-limit bypass of intent.

### W4 — Collaboration writes lack entity-in-project checks

- **Severity**: Medium (integrity; latent before write tools)  
- **Location**:  
  - `lib/elx_mcp/collaboration.ex:16-23` (`create_comment`)  
  - `lib/elx_mcp/collaboration.ex:39-46` (`create_attachment`)  
  - `lib/elx_mcp/collaboration.ex:49-72` (`create_worklog` — relies on Multi + `increment_time_spent` failure to roll back cross-project ticket)  
  - `lib/elx_mcp/collaboration.ex:75-86` (`record_changelog`)  
- **Issue**: `project_id` is forced from Scope (good), but polymorphic `commentable_*` / `attachable_*` / `entity_*` are not validated with `ensure_same_project`. Worklog FK allows any global `ticket_id`; cross-project is rolled back only because `increment_time_spent/3` is project-scoped inside Multi — fragile if Multi shape changes.  
- **Fix**: Resolve entity by id+`scope.project_id` before insert; for worklog call `ensure_same_project(Ticket, ticket_id, project_id)` first; stop casting `ticket_id` — `put_change` only.  
- **OWASP**: A01 Broken Access Control (integrity).

### W5 — Mass-assignable integrity fields on write schemas

- **Severity**: Low–Medium  
- **Location**:  
  - `lib/elx_mcp/projects/ticket.ex:51` — `:time_spent_seconds` castable on create  
  - `lib/elx_mcp/collaboration/attachment.ex:34` — `:storage_path` client-controlled  
  - `lib/elx_mcp/collaboration/comment.ex:28` / `worklog.ex:28` / `changelog.ex:28` — `author_email` / `actor_email` not forced to `scope.actor_email`  
  - `lib/elx_mcp/collaboration/changelog.ex:32` — `:inserted_at` castable (backdating)  
- **Issue**: Write holders with `project:write` can forge spent time, spoof actors, or set arbitrary storage paths (path-traversal risk when file serve is added).  
- **Fix**: Drop `:time_spent_seconds` from ticket cast (derive from worklogs only); set actor emails via `put_change(scope.actor_email)`; server-generate `storage_path`; set `inserted_at` only in context.  
- **OWASP**: A04 / mass assignment.

### W6 — `increment_time_spent/3` is unscoped public API

- **Severity**: Low (footgun)  
- **Location**: `lib/elx_mcp/projects.ex:292-300`  
- **Issue**: Accepts bare `project_id` without `authorize_write`. Safe only if all callers are trusted.  
- **Fix**: Prefer private function or `(%Scope{}, ticket_id, seconds)` + `authorize_write`.

---

## SUGGESTION

### S1 — Session bind race handling is correct; document first-binder-wins

- **Location**: `session_bind.ex:44-51`  
- `insert_new` + re-`verify` handles concurrent first bind. First authenticated principal to POST with that session id owns lifecycle. Entropy of Anubis session ids + TLS assumed. No change required; note in ops docs.

### S2 — RateLimit `ensure_table!/0` recreates under caller if Application table gone

- **Location**: `rate_limit.ex:80-85`, same pattern `session_bind.ex:11-27`  
- If Application process dies and ETS is lost, next request re-owns tables (original bug class partially returns). Prefer supervised owner process as sole creator; make `check` fail closed if table missing.

### S3 — 401 vs 403 distinguishes auth failure vs session ownership

- **Location**: `mcp_auth.ex:102-114`  
- Minor info leakage (session exists / bound to other). Acceptable; use uniform 404-style if hardening.

### S4 — Multi-node SessionBind / RateLimit not cluster-safe

- Documented; sticky sessions or Redis required for HA. No single-node bug.

### S5 — `authorize_write` is membership check only

- **Location**: `auth.ex:93-95`  
- Correct for catalog scopes. When write MCP tools ship, keep calling at every context mutation (already done).

---

## Security Posture (delta)

| Area | Status | Notes |
|------|--------|--------|
| Session lifecycle bind | ⚠️ | Bound after first POST; pre-bind + no TTL residual |
| Mutation authz (`project:write`) | ✅ | All public `create_*` / `update_ticket_parent` / collab writes |
| Mass assign `project_id` / `key` | ✅ | Removed from cast; `put_change` from Scope |
| Cross-project FK on Projects creates | ✅ | `ensure_same_project` on story/ticket/sprint board links |
| Rate limit ownership | ✅ | Application.start owns ETS + prune |
| Rate limit effectiveness | ⚠️ | IP-only; proxy awareness missing |
| Collab entity tenancy | ⚠️ | project_id forced; entity id not re-checked |
| Atom / SQL / raw XSS in this delta | ✅ | Clean |

---

## Recommendations (priority)

1. **Fail-closed DELETE/GET** when session unbound; bind as early as session id is known.  
2. **TTL/cap SessionBind** ETS entries.  
3. **`ensure_same_project`** (or id resolve) on all collab polymorphic targets + worklog ticket.  
4. **Strip integrity fields** from casts (`time_spent_seconds`, `storage_path`, actor emails, `inserted_at`).  
5. **Prod remote IP** from trusted proxy headers; plan per-key + multi-node limiter.

## Tools to run manually

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
- `mix test test/elx_mcp/auth/session_bind_test.exs test/elx_mcp_web/plugs/mcp_auth_test.exs test/elx_mcp_web/plugs/mcp_auth_rate_limit_test.exs`
