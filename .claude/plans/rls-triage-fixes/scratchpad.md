# Scratchpad: rls-triage-fixes

## Decisions

- Prefer **BYPASSRLS owner role** for SECDEF helpers; **remove** `app.bypass_rls` from policies (user chose “just fix them” with this default).
- `with_tenant`: do not call clear SQL after `fun` when TX may be aborted; LOCAL ends with TX.
- `increment_time_spent`: keep callable from Multi without Scope; `@doc false` only.
- Plan input = triage (all 19 findings); no re-research agents (plan-from-review rule).

## Dead ends / avoid

- Keeping policy GUC and only “reset on exit” — weaker than BYPASSRLS redesign.
- Requiring Scope on `increment_time_spent` inside Multi under existing tenant — unnecessary churn.
- Connecting as `postgres` to hermes over the network (psql from dev laptop, port 5481) to run
  `create_elx_mcp_secdef_role.sql` — **fails by design**: pg_hba on hermes has no remote entry for
  user `postgres` (SSL or non-SSL), confirmed 2026-08-02 against current dev IP. This is intended
  hardening (DB_SEC.md §5.1/§6.5: no remote superuser trust), not a bug. Must run the SQL via a
  **local** connection on the hermes host itself (SSH in, then `sudo -u postgres psql -d elx_mcp_dev`
  using the Unix socket). Schema/table GRANTs in the manual SQL are per-database — repeat those
  (not `CREATE ROLE` / `GRANT elx_mcp_secdef TO elx_mcp_dev`, which are cluster-wide) against
  `elx_mcp_test` too before `mix ecto.migrate` there.

## Fixes applied

- P2-T2 retry failed with `permission denied for schema public` on
  `ALTER FUNCTION elx_mcp_lookup_api_key(bytea) OWNER TO elx_mcp_secdef`. Root cause:
  Postgres requires the **new owning role** to hold `CREATE` on the object's schema for
  `ALTER ... OWNER TO` (not just `USAGE`, which is all the bootstrap SQL granted). Fixed in
  `20260802171043_rls_bypassrls_owner.exs` (`ensure_secdef_role!` now runs
  `GRANT USAGE, CREATE ON SCHEMA public TO elx_mcp_secdef` unconditionally, not only inside the
  `IF NOT EXISTS role` branch — hermes already has the role from the manual bootstrap, so the
  conditional branch would never re-fire). Also fixed `priv/repo/manual/create_elx_mcp_secdef_role.sql`
  and `DB_SEC.md` §13.3 to match. `elx_mcp_dev` owns the `elx_mcp_dev`/`elx_mcp_test` databases, so
  it effectively owns `public` (via `pg_database_owner` in PG15+) and can run this GRANT itself —
  **no further hermes SSH/superuser step needed**, just re-run `mix ecto.migrate` (dev) and
  `MIX_ENV=test mix ecto.migrate` (test).

## Spike results (fill during P0)

- [x] Can migration CREATE ROLE BYPASSRLS? **NO**
  - identity: `elx_mcp_dev`, is_superuser=off, rolcreaterole=false, rolbypassrls=false
  - error: `permission denied to create role` (needs CREATEROLE / superuser)
  - superuser on cluster: `postgres`
  - path **(b)**: manual superuser DDL + migration assumes `elx_mcp_secdef` exists, then ALTER OWNER + REVOKE/GRANT + policy rewrite
- [x] App DB role: hermes dev/test = `elx_mcp_dev` / DB `elx_mcp_dev` (and test DB via env)
- Manual bootstrap (run as postgres on hermes):
  ```sql
  CREATE ROLE elx_mcp_secdef NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS;
  GRANT elx_mcp_secdef TO elx_mcp_dev;  -- so app can ALTER FUNCTION OWNER TO
  GRANT USAGE ON SCHEMA public TO elx_mcp_secdef;
  ```

## Notes for implementer

- Untracked migrations `170000` / `170100` may still be uncommitted; new migration should assume they are applied.
- Search codebase for `app.bypass_rls` after Phase 2 and remove app-side set_config if unused.
- App-side `app.bypass_rls` removed from `Repo` (only remains in old migrations + DB policies until 171043 applies).

### [session] HANDOFF: rls-triage-fixes
Status: 11/13 tasks done. Blocker: P2-T2 (hermes superuser DDL).
Next: As `postgres` on hermes run `priv/repo/manual/create_elx_mcp_secdef_role.sql`, then `mix ecto.migrate` (dev + test DBs), then full `mix test`.
Key decisions:
- with_tenant: clear GUC *outside* nested TX after return (Sandbox LOCAL leak); never clear after fun inside aborted TX
- create_project: `Repo.rollback(cs)` on constraint error → `{:error, %Ecto.Changeset{}}`
- Repo.load needs 16-byte UUID dump format from SECDEF row maps
- CI creates secdef role automatically (POSTGRES_USER is superuser)
