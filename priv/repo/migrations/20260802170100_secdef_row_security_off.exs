defmodule ElxMcp.Repo.Migrations.SecdefRowSecurityOff do
  @moduledoc """
  Restores a controlled bypass GUC in policies and rewrites SECURITY DEFINER
  helpers as PL/pgSQL that set `app.bypass_rls=on` **only inside the function**.

  Why: with FORCE RLS, the table owner is still subject to policies, and
  non-superusers cannot `SET row_security = off` on function definitions.
  """
  use Ecto.Migration

  @tables_with_project_id ~w(
    boards sprints components epics user_stories tickets
    comments attachments worklogs changelogs api_keys
  )

  def up do
    recreate_policies_with_bypass()
    recreate_secdef_functions()
  end

  def down do
    :ok
  end

  defp uuid_match(column) do
    "#{column} = NULLIF(current_setting('app.project_id', true), '')::uuid"
  end

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

  defp recreate_secdef_functions do
    # PL/pgSQL can set_config LOCAL for the function body only.
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
