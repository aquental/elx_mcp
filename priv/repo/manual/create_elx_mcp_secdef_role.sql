-- Run as superuser (postgres) on hermes before mix ecto.migrate for
-- 20260802171043_rls_bypassrls_owner (and follow-up least-privilege migration).
--
-- App role elx_mcp_dev cannot CREATE ROLE / BYPASSRLS (spike 2026-08-02).
--
-- Lifecycle:
--   1. Bootstrap (this file): create role + temporary membership + CREATE on public
--   2. Migrate 171043: re-own SECDEF functions, GRANT EXECUTE to app
--   3. Migrate 182038 (least privilege): REVOKE CREATE; REVOKE membership from app
--
-- Membership is only needed during migrate/bootstrap. Runtime app must NOT be a
-- member of elx_mcp_secdef (SET ROLE would grant BYPASSRLS + table DML).
-- To re-own functions later: GRANT elx_mcp_secdef TO elx_mcp_dev; ...; REVOKE again.

CREATE ROLE elx_mcp_secdef NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS;

-- Temporary: allow elx_mcp_dev to ALTER FUNCTION ... OWNER TO elx_mcp_secdef
-- (revoked by migration 20260802182038 after ownership transfer)
GRANT elx_mcp_secdef TO elx_mcp_dev;

-- CREATE is required during OWNER TO (not just USAGE). Revoked after migrate.
GRANT USAGE, CREATE ON SCHEMA public TO elx_mcp_secdef;

-- Table DML for SECDEF body (BYPASSRLS skips policies; still needs GRANT):
GRANT SELECT, UPDATE ON api_keys TO elx_mcp_secdef;
GRANT SELECT ON projects TO elx_mcp_secdef;

-- After full migrate (through 20260802182038), as superuser on hermes:
--   REVOKE CREATE ON SCHEMA public FROM elx_mcp_secdef;
--   REVOKE elx_mcp_secdef FROM elx_mcp_dev;
-- App role lacks ADMIN on elx_mcp_secdef, so membership REVOKE must be superuser.
