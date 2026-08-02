defmodule ElxMcp.Repo.Migrations.RlsSecdefLeastPrivilege do
  @moduledoc """
  Least-privilege follow-up after SECDEF ownership transfer (20260802171043).

  1. Grant EXECUTE on elx_mcp_* SECDEF functions to CURRENT_USER and
     `elx_mcp_dev` (if different) for portable app roles.
  2. REVOKE CREATE on schema public from `elx_mcp_secdef` (USAGE + table DML remain).
  3. REVOKE membership of `elx_mcp_secdef` from the app role so runtime cannot
     `SET ROLE elx_mcp_secdef` (BYPASSRLS blast radius).

  **Ops**: Membership is only needed during migrate/bootstrap (ALTER OWNER / grants
  under NOINHERIT). To re-own functions later, temporarily:
  `GRANT elx_mcp_secdef TO <app_role>;` then re-run ownership SQL and REVOKE again.

  **Never** `ecto.rollback` past 20260802171043 on shared/prod (restores client
  `app.bypass_rls`). Intermediate 170000/170100 leave PUBLIC EXECUTE if the
  chain stops mid-way — always migrate fully through this migration.
  """
  use Ecto.Migration

  @app_role "elx_mcp_dev"
  @secdef_role "elx_mcp_secdef"

  def up do
    grant_execute_portable()
    revoke_secdef_create_on_public()
    revoke_secdef_membership()
  end

  def down do
    # Restore bootstrap capability for re-own / grant fixups
    execute("""
    DO $$
    BEGIN
      BEGIN
        EXECUTE 'GRANT #{@secdef_role} TO CURRENT_USER';
      EXCEPTION WHEN undefined_object OR invalid_grant_operation THEN
        NULL;
      END;
      BEGIN
        EXECUTE 'GRANT #{@secdef_role} TO #{@app_role}';
      EXCEPTION WHEN undefined_object OR invalid_grant_operation OR duplicate_object THEN
        NULL;
      END;
      BEGIN
        EXECUTE 'GRANT USAGE, CREATE ON SCHEMA public TO #{@secdef_role}';
      EXCEPTION WHEN undefined_object THEN
        NULL;
      END;
    END
    $$;
    """)
  end

  defp grant_execute_portable do
    # SET ROLE only while still a member (pre-revoke). NOINHERIT requires SET ROLE.
    execute("""
    DO $$
    DECLARE
      sig text;
      sigs text[] := ARRAY[
        'elx_mcp_lookup_api_key(bytea)',
        'elx_mcp_touch_api_key(uuid, timestamptz)',
        'elx_mcp_get_project_by_key(text)',
        'elx_mcp_get_project(uuid)',
        'elx_mcp_get_api_key(uuid)',
        'elx_mcp_list_projects()'
      ];
      is_member boolean;
      cur text := current_user;
    BEGIN
      SELECT pg_has_role(cur, '#{@secdef_role}', 'member') INTO is_member;

      IF is_member THEN
        EXECUTE 'SET LOCAL ROLE #{@secdef_role}';
      END IF;

      FOREACH sig IN ARRAY sigs LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO CURRENT_USER', sig);
        IF cur IS DISTINCT FROM '#{@app_role}' THEN
          EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO #{@app_role}', sig);
        END IF;
      END LOOP;

      IF is_member THEN
        EXECUTE 'RESET ROLE';
      END IF;
    END
    $$;
    """)
  end

  defp revoke_secdef_create_on_public do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@secdef_role}') THEN
        EXECUTE 'REVOKE CREATE ON SCHEMA public FROM #{@secdef_role}';
        -- Keep USAGE so owner can still resolve objects; table DML from prior migration remains
        EXECUTE 'GRANT USAGE ON SCHEMA public TO #{@secdef_role}';
      END IF;
    END
    $$;
    """)
  end

  defp revoke_secdef_membership do
    # On hermes, only a role with ADMIN on elx_mcp_secdef (superuser) can REVOKE
    # membership granted by postgres. CI (superuser app role) succeeds here.
    # If insufficient_privilege: run as superuser:
    #   REVOKE elx_mcp_secdef FROM elx_mcp_dev;
    execute("""
    DO $$
    DECLARE
      cur text := current_user;
      is_super boolean;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@secdef_role}') THEN
        RETURN;
      END IF;

      SELECT rolsuper INTO is_super FROM pg_roles WHERE rolname = cur;

      -- Drop app ability to SET ROLE into BYPASSRLS secdef
      BEGIN
        EXECUTE format('REVOKE #{@secdef_role} FROM %I', cur);
      EXCEPTION
        WHEN undefined_object OR invalid_grant_operation OR insufficient_privilege THEN
          IF is_super THEN
            RAISE;
          END IF;
          RAISE NOTICE
            'Could not REVOKE #{@secdef_role} FROM % (need ADMIN/superuser). Run as superuser: REVOKE #{@secdef_role} FROM #{@app_role};',
            cur;
      END;

      IF cur IS DISTINCT FROM '#{@app_role}' THEN
        BEGIN
          EXECUTE 'REVOKE #{@secdef_role} FROM #{@app_role}';
        EXCEPTION
          WHEN undefined_object OR invalid_grant_operation OR insufficient_privilege THEN
            NULL;
        END;
      END IF;
    END
    $$;
    """)
  end
end
