# Security Audit: RLS triage fixes

## Executive Summary

**Risk: Medium (residual privilege design), no Critical on the intended fix path.**

B2/B3 goals land correctly: client-settable `app.bypass_rls` is gone from policies; SECDEF helpers run as `elx_mcp_secdef` with `BYPASSRLS` + fixed `search_path`; `EXECUTE` is revoked from `PUBLIC` and granted only to the app role; attachment `storage_path` is server-authored; pool/tenant GUC hygiene is sound.

Main residual risk is **blast radius of the app role’s membership in `elx_mcp_secdef`** (can `SET ROLE` into BYPASSRLS + read/update all `api_keys`) and **hardcoded EXECUTE grant** to `elx_mcp_dev` only. No new HTTP authz hole found for these changes.

## Critical Vulnerabilities

_None in new code that re-opens client RLS bypass or client-controlled storage paths._

## Findings

### WARNING — App role membership of BYPASSRLS secdef (privilege escalation path)

- **Severity**: High (conditional on raw SQL / compromised app DB session)
- **Location**: `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:67-68,86-91,271`; `priv/repo/manual/create_elx_mcp_secdef_role.sql:9`
- **Issue**: `GRANT elx_mcp_secdef TO elx_mcp_dev` persists at runtime. With `NOINHERIT`, privileges are not automatic, but any session as `elx_mcp_dev` can `SET ROLE elx_mcp_secdef` and inherit **BYPASSRLS** plus `SELECT/UPDATE` on **all** `api_keys` (incl. `key_hash`) and `SELECT` on all `projects` — without needing SECDEF function predicates.
- **Fix**: Prefer superuser-only ownership/GRANT during bootstrap; after `ALTER FUNCTION … OWNER TO` + EXECUTE grants, **`REVOKE elx_mcp_secdef FROM elx_mcp_dev`** if runtime reown is unnecessary. Keep table grants on secdef minimal (already mostly so).
- **OWASP**: A01 Broken Access Control / privilege boundary

### WARNING — Hardcoded EXECUTE grant target `elx_mcp_dev`

- **Severity**: Medium
- **Location**: `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:35,274`
- **Issue**: `GRANT EXECUTE … TO elx_mcp_dev` is hardcoded. `spec/DB_SEC.md` documents a future/prod `elx_mcp_app` role. If the runtime DB user ≠ `elx_mcp_dev`, either SECDEF auth fails closed (availability) or operators may re-open with overly broad grants. Plan W1 asked for “app role / config role”.
- **Fix**: Grant to `current_user` at migrate time and/or a configured role list (`elx_mcp_dev`, `elx_mcp_app`); never re-grant `PUBLIC`.

### WARNING — `down/0` restores client-settable bypass hatch

- **Severity**: Medium (ops)
- **Location**: `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:45-49,302-358`
- **Issue**: Rollback reintroduces `current_setting('app.bypass_rls') = 'on'` in policies — any DB client that can `set_config` regains full tenant bypass. Intentional for W7, dangerous if `ecto.rollback` is run on shared/prod.
- **Fix**: Document “do not down in prod”; or make `down` irreversible and leave policies UUID-only.

### WARNING — Permanent `CREATE` on `public` for secdef

- **Severity**: Low–Medium
- **Location**: `…_rls_bypassrls_owner.exs:101`; `create_elx_mcp_secdef_role.sql:13`
- **Issue**: `GRANT USAGE, CREATE ON SCHEMA public TO elx_mcp_secdef` is required for `OWNER TO` but left in place. Combined with app membership + `SET ROLE`, secdef can create objects in `public`.
- **Fix**: After ownership transfer, `REVOKE CREATE ON SCHEMA public FROM elx_mcp_secdef` (retain table DML grants).

### SUGGESTION — Attachment still casts `uploaded_by_email`

- **Severity**: Low
- **Location**: `lib/elx_mcp/collaboration/attachment.ex:28-34` vs `collaboration.ex:71`
- **Issue**: `create_attachment` overwrites via `put_change`, so current path is safe; Comment correctly omits `author_email` from cast. Inconsistent — future callers of `Attachment.changeset/2` alone could spoof uploader.
- **Fix**: Drop `:uploaded_by_email` from cast (mirror Comment).

### SUGGESTION — Nested `with_tenant` restore when `prev` is nil

- **Severity**: Low
- **Location**: `lib/elx_mcp/repo.ex:70-76`
- **Issue**: If nested switch sees `prev == nil`, process dict is cleared but GUC is not reset to empty/prior — residual tenant for outer depth. Unlikely under normal depth-0 entry (always sets `@project_key`).
- **Fix**: In `else`, `set_tenant_guc!("")` or equivalent clear.

### SUGGESTION — SECDEF helpers remain full cross-tenant bootstrap surface

- **Severity**: Low (by design; not HTTP-mounted)
- **Location**: `auth.ex:129-134,151-155`; `tenancy.ex:18-65`; migration funcs `elx_mcp_list_projects`, `elx_mcp_get_api_key`, `elx_mcp_get_project*`
- **Issue**: Any code path with DB credentials can enumerate projects and load API key rows (hashes) by id via EXECUTE. Documented admin/bootstrap; ensure these never become unauthenticated HTTP.
- **Fix**: Keep mix/admin-only; optionally redact `key_hash` from `get_api_key` return shape for non-verify paths.

## What looks correct (new code)

| Area | Assessment |
|------|------------|
| B2 policies | UUID GUC only; no `app.bypass_rls` in `up` |
| SECDEF | `SECURITY DEFINER`, `SET search_path = public`, no in-body bypass GUC |
| EXECUTE | `REVOKE … FROM PUBLIC`; grant app role only |
| `with_tenant` | `SET LOCAL`; clear after nested TX (Sandbox); process dict in `after` |
| Pool | `after_connect` session-clears `app.project_id` (`runtime.exs:276-277`) |
| Auth | Empty scopes rejected; allowlist; timing-safe email; missing project → unauthorized |
| W4 path | `storage_path` not cast; server path `projects/{id}/attachments/{uuid}` |
| Limits | Collab list clamps `min(200)` / `max(1)` |

## Pre-existing (one-line)

- `lib/elx_mcp/auth.ex:27` — `create_api_key/3` is unscoped bootstrap (mix-only today).
- `lib/elx_mcp/tenancy.ex:18` — `list_projects/0` SECDEF cross-tenant by design.
- `lib/elx_mcp/mcp/helpers.ex:12-42` — scope rebuilt from assigns if `current_scope` missing (trust plug assigns).
- `config/runtime.exs:170-178` — `DB_SSL=verify_none` allowed outside prod with warn only in prod.

## Security Posture (this diff)

- **RLS bypass hatch**: ✅ removed from policies
- **SECDEF ownership**: ✅ BYPASSRLS role; ⚠️ membership + CREATE residual
- **Grants**: ✅ no PUBLIC EXECUTE; ⚠️ hardcoded role name
- **Tenant GUC hygiene**: ✅ LOCAL + after_connect + process dict
- **Attachment path**: ✅ server-only
- **Auth boundaries**: ✅ verify + empty scopes; bootstrap APIs remain privileged by convention

## Recommendations (priority)

1. After migrate: evaluate **`REVOKE elx_mcp_secdef FROM <app_role>`** and **`REVOKE CREATE ON SCHEMA public FROM elx_mcp_secdef`**.
2. Parameterize EXECUTE grantee(s) for prod `elx_mcp_app`.
3. Never run this migration’s `down` on shared/prod DBs.
4. Align Attachment cast with Comment (drop actor email from cast).
5. Manually: `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`.

## Tools to Recommend

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
- SQL: `\df+ elx_mcp_*` + `SELECT proacl …` to confirm no PUBLIC execute; `SELECT rolbypassrls FROM pg_roles WHERE rolname='elx_mcp_secdef'`
