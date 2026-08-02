defmodule ElxMcp.Repo.Migrations.RlsBypassrlsOwner do
  @moduledoc """
  Removes client-settable `app.bypass_rls` from RLS policies (B2/B3).

  SECURITY DEFINER helpers are re-owned by role `elx_mcp_secdef` (BYPASSRLS),
  so they no longer need a policy hatch GUC. EXECUTE is revoked from PUBLIC
  and granted only to the app role.

  **Prerequisite** (superuser on hermes — `elx_mcp_dev` cannot CREATE ROLE):

      CREATE ROLE elx_mcp_secdef NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS;
      GRANT elx_mcp_secdef TO elx_mcp_dev;
      GRANT USAGE, CREATE ON SCHEMA public TO elx_mcp_secdef;

  See `priv/repo/manual/create_elx_mcp_secdef_role.sql` and `spec/DB_SEC.md`.

  `down/0` restores the v1.9 policy+function shape (client-settable `app.bypass_rls`
  inside SECDEF and policies). **Never `ecto.rollback` past this migration on
  shared/prod.** Intermediate migrations 170000/170100 can leave PUBLIC EXECUTE
  if the chain stops mid-way — always migrate fully through least-privilege
  follow-up `20260802182038_rls_secdef_least_privilege`.
  """
  use Ecto.Migration

  @tables_with_project_id ~w(
    boards sprints components epics user_stories tickets
    comments attachments worklogs changelogs api_keys
  )

  @secdef_functions [
    {"elx_mcp_lookup_api_key", "bytea"},
    {"elx_mcp_touch_api_key", "uuid, timestamptz"},
    {"elx_mcp_get_project_by_key", "text"},
    {"elx_mcp_get_project", "uuid"},
    {"elx_mcp_get_api_key", "uuid"},
    {"elx_mcp_list_projects", ""}
  ]

  @app_role "elx_mcp_dev"
  @secdef_role "elx_mcp_secdef"

  def up do
    ensure_secdef_role!()
    recreate_policies_uuid_only()
    recreate_secdef_functions()
    reown_and_grant_functions()
  end

  def down do
    recreate_policies_with_bypass()
    recreate_secdef_functions_with_bypass_guc()
    # Best-effort: return ownership to app role if we can
    reown_to_app_role()
  end

  defp ensure_secdef_role! do
    # CI: POSTGRES_USER=elx_mcp_dev is superuser → CREATE ROLE succeeds.
    # hermes: elx_mcp_dev is not CREATEROLE → requires manual SQL once (see moduledoc).
    execute("""
    DO $$
    DECLARE
      is_super boolean;
      can_create boolean;
    BEGIN
      SELECT rolsuper, rolcreaterole INTO is_super, can_create
      FROM pg_roles WHERE rolname = current_user;

      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@secdef_role}') THEN
        IF is_super OR can_create THEN
          CREATE ROLE #{@secdef_role} NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS;
          GRANT #{@secdef_role} TO CURRENT_USER;
          GRANT USAGE ON SCHEMA public TO #{@secdef_role};
        ELSE
          RAISE EXCEPTION
            'Missing role #{@secdef_role}. Run as superuser: CREATE ROLE #{@secdef_role} NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS; GRANT #{@secdef_role} TO elx_mcp_dev; See priv/repo/manual/create_elx_mcp_secdef_role.sql';
        END IF;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = '#{@secdef_role}' AND rolbypassrls
      ) THEN
        IF is_super THEN
          EXECUTE 'ALTER ROLE #{@secdef_role} BYPASSRLS';
        ELSE
          RAISE EXCEPTION
            'Role #{@secdef_role} exists but lacks BYPASSRLS. As superuser: ALTER ROLE #{@secdef_role} BYPASSRLS;';
        END IF;
      END IF;

      -- Ensure app role can reown functions
      BEGIN
        EXECUTE 'GRANT #{@secdef_role} TO CURRENT_USER';
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END
    $$;
    """)

    # ALTER FUNCTION ... OWNER TO requires the new owner to hold CREATE on the
    # function's schema (not just USAGE) — must run every time, not only on
    # first role creation, since a pre-existing role (e.g. bootstrapped
    # manually on hermes before this grant was added) would otherwise never
    # pick it up.
    execute("GRANT USAGE, CREATE ON SCHEMA public TO #{@secdef_role}")
  end

  defp uuid_match(column) do
    "#{column} = NULLIF(current_setting('app.project_id', true), '')::uuid"
  end

  defp recreate_policies_uuid_only do
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")
    id_match = uuid_match("id")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (#{id_match})
      WITH CHECK (#{id_match})
    """)

    for table <- @tables_with_project_id do
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")
      col_match = uuid_match("project_id")

      execute("""
      CREATE POLICY tenant_isolation ON #{table}
        FOR ALL
        USING (#{col_match})
        WITH CHECK (#{col_match})
      """)
    end

    execute("DROP POLICY IF EXISTS tenant_isolation ON component_links")

    execute("""
    CREATE POLICY tenant_isolation ON component_links
      FOR ALL
      USING (
        EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id = NULLIF(current_setting('app.project_id', true), '')::uuid
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id = NULLIF(current_setting('app.project_id', true), '')::uuid
        )
      )
    """)
  end

  defp recreate_secdef_functions do
    # No set_config bypass — owner has BYPASSRLS (B2/B3).
    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_lookup_api_key(p_hash bytea)
    RETURNS SETOF api_keys
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT a.*
      FROM api_keys a
      WHERE a.key_hash = p_hash
        AND a.revoked_at IS NULL;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_touch_api_key(p_id uuid, p_at timestamptz)
    RETURNS void
    LANGUAGE sql
    VOLATILE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      UPDATE api_keys
      SET last_used_at = p_at
      WHERE id = p_id;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_project_by_key(p_key text)
    RETURNS SETOF projects
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT p.*
      FROM projects p
      WHERE p.key = upper(trim(p_key))
      LIMIT 1;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_project(p_id uuid)
    RETURNS SETOF projects
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT p.*
      FROM projects p
      WHERE p.id = p_id
      LIMIT 1;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_api_key(p_id uuid)
    RETURNS SETOF api_keys
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT a.*
      FROM api_keys a
      WHERE a.id = p_id
      LIMIT 1;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_list_projects()
    RETURNS SETOF projects
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT p.*
      FROM projects p
      ORDER BY p.key ASC;
    $$
    """)
  end

  defp reown_and_grant_functions do
    # Table privileges for SECDEF owner (BYPASSRLS skips policies; still needs GRANT)
    execute("GRANT SELECT, UPDATE ON api_keys TO #{@secdef_role}")
    execute("GRANT SELECT ON projects TO #{@secdef_role}")

    for {name, args} <- @secdef_functions do
      sig = if args == "", do: "#{name}()", else: "#{name}(#{args})"

      execute("ALTER FUNCTION #{sig} OWNER TO #{@secdef_role}")
    end

    # After ownership transfer, only the owner (or a SET ROLE to it) can REVOKE/GRANT.
    # elx_mcp_dev is a member of elx_mcp_secdef (bootstrap SQL); NOINHERIT means we
    # must SET ROLE for privilege changes. One DO block keeps the role for all funcs.
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
    BEGIN
      EXECUTE 'SET LOCAL ROLE #{@secdef_role}';
      FOREACH sig IN ARRAY sigs LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO #{@app_role}', sig);
      END LOOP;
      EXECUTE 'RESET ROLE';
    END
    $$;
    """)
  end

  defp reown_to_app_role do
    for {name, args} <- @secdef_functions do
      sig = if args == "", do: "#{name}()", else: "#{name}(#{args})"

      execute("""
      DO $$
      BEGIN
        BEGIN
          EXECUTE 'ALTER FUNCTION #{sig} OWNER TO #{@app_role}';
        EXCEPTION WHEN insufficient_privilege OR undefined_object THEN
          NULL;
        END;
      END
      $$;
      """)
    end
  end

  # --- down helpers: restore bypass-GUC policy hatch (v1.9) ---

  defp recreate_policies_with_bypass do
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")
    id_match = uuid_match("id")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (
        current_setting('app.bypass_rls', true) = 'on'
        OR (#{id_match})
      )
      WITH CHECK (
        current_setting('app.bypass_rls', true) = 'on'
        OR (#{id_match})
      )
    """)

    for table <- @tables_with_project_id do
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")
      col_match = uuid_match("project_id")

      execute("""
      CREATE POLICY tenant_isolation ON #{table}
        FOR ALL
        USING (
          current_setting('app.bypass_rls', true) = 'on'
          OR (#{col_match})
        )
        WITH CHECK (
          current_setting('app.bypass_rls', true) = 'on'
          OR (#{col_match})
        )
      """)
    end

    execute("DROP POLICY IF EXISTS tenant_isolation ON component_links")

    execute("""
    CREATE POLICY tenant_isolation ON component_links
      FOR ALL
      USING (
        current_setting('app.bypass_rls', true) = 'on'
        OR EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id = NULLIF(current_setting('app.project_id', true), '')::uuid
        )
      )
      WITH CHECK (
        current_setting('app.bypass_rls', true) = 'on'
        OR EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id = NULLIF(current_setting('app.project_id', true), '')::uuid
        )
      )
    """)
  end

  defp recreate_secdef_functions_with_bypass_guc do
    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_lookup_api_key(p_hash bytea)
    RETURNS SETOF api_keys
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      RETURN QUERY
        SELECT a.*
        FROM api_keys a
        WHERE a.key_hash = p_hash
          AND a.revoked_at IS NULL;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_touch_api_key(p_id uuid, p_at timestamptz)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      UPDATE api_keys
      SET last_used_at = p_at
      WHERE id = p_id;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_project_by_key(p_key text)
    RETURNS SETOF projects
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      RETURN QUERY
        SELECT p.*
        FROM projects p
        WHERE p.key = upper(trim(p_key))
        LIMIT 1;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_project(p_id uuid)
    RETURNS SETOF projects
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      RETURN QUERY
        SELECT p.*
        FROM projects p
        WHERE p.id = p_id
        LIMIT 1;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_get_api_key(p_id uuid)
    RETURNS SETOF api_keys
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      RETURN QUERY
        SELECT a.*
        FROM api_keys a
        WHERE a.id = p_id
        LIMIT 1;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_list_projects()
    RETURNS SETOF projects
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $$
    BEGIN
      PERFORM set_config('app.bypass_rls', 'on', true);
      RETURN QUERY
        SELECT p.*
        FROM projects p
        ORDER BY p.key ASC;
    END;
    $$
    """)
  end
end
