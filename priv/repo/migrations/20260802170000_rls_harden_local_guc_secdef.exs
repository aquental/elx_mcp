defmodule ElxMcp.Repo.Migrations.RlsHardenLocalGucSecdef do
  @moduledoc """
  Hardens RLS:

  1. Policies compare `project_id` / `id` as **uuid** (not text).
  2. Removes app-level `app.bypass_rls` escape hatch from policies.
  3. Adds **SECURITY DEFINER** helpers for auth/bootstrap lookups that must
     see rows before a tenant GUC exists (API key by hash, project by key, list projects).

  App code must set `app.project_id` via `Repo.with_tenant/2` (transaction-local GUC).
  """
  use Ecto.Migration

  @tables_with_project_id ~w(
    boards sprints components epics user_stories tickets
    comments attachments worklogs changelogs api_keys
  )

  def up do
    recreate_project_policy()

    for table <- @tables_with_project_id do
      recreate_project_id_policy(table)
    end

    recreate_component_links_policy()
    create_security_definer_functions()
  end

  def down do
    execute("DROP FUNCTION IF EXISTS elx_mcp_lookup_api_key(bytea)")
    execute("DROP FUNCTION IF EXISTS elx_mcp_touch_api_key(uuid, timestamptz)")
    execute("DROP FUNCTION IF EXISTS elx_mcp_get_project_by_key(text)")
    execute("DROP FUNCTION IF EXISTS elx_mcp_get_project(uuid)")
    execute("DROP FUNCTION IF EXISTS elx_mcp_get_api_key(uuid)")
    execute("DROP FUNCTION IF EXISTS elx_mcp_list_projects()")

    # Restore text + bypass policies (previous generation)
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (
        current_setting('app.bypass_rls', true) = 'on'
        OR id::text = current_setting('app.project_id', true)
      )
      WITH CHECK (
        current_setting('app.bypass_rls', true) = 'on'
        OR id::text = current_setting('app.project_id', true)
      )
    """)

    for table <- @tables_with_project_id do
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")

      execute("""
      CREATE POLICY tenant_isolation ON #{table}
        FOR ALL
        USING (
          current_setting('app.bypass_rls', true) = 'on'
          OR project_id::text = current_setting('app.project_id', true)
        )
        WITH CHECK (
          current_setting('app.bypass_rls', true) = 'on'
          OR project_id::text = current_setting('app.project_id', true)
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
            AND c.project_id::text = current_setting('app.project_id', true)
        )
      )
      WITH CHECK (
        current_setting('app.bypass_rls', true) = 'on'
        OR EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id::text = current_setting('app.project_id', true)
        )
      )
    """)
  end

  defp tenant_uuid_expr(column) do
    "#{column} = NULLIF(current_setting('app.project_id', true), '')::uuid"
  end

  defp recreate_project_policy do
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")
    expr = tenant_uuid_expr("id")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (#{expr})
      WITH CHECK (#{expr})
    """)
  end

  defp recreate_project_id_policy(table) do
    execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")
    expr = tenant_uuid_expr("project_id")

    execute("""
    CREATE POLICY tenant_isolation ON #{table}
      FOR ALL
      USING (#{expr})
      WITH CHECK (#{expr})
    """)
  end

  defp recreate_component_links_policy do
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

  defp create_security_definer_functions do
    # Owner of these functions is the migration role (table owner); runs with owner rights → bypasses RLS.
    execute("""
    CREATE OR REPLACE FUNCTION elx_mcp_lookup_api_key(p_hash bytea)
    RETURNS SETOF api_keys
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    SET row_security = off
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
    SECURITY DEFINER
    SET search_path = public
    SET row_security = off
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
    SET row_security = off
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
    SET row_security = off
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
    SET row_security = off
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
    SET row_security = off
    AS $$
      SELECT p.*
      FROM projects p
      ORDER BY p.key ASC;
    $$
    """)

    for fn_sig <- [
          "elx_mcp_lookup_api_key(bytea)",
          "elx_mcp_touch_api_key(uuid, timestamptz)",
          "elx_mcp_get_project_by_key(text)",
          "elx_mcp_get_project(uuid)",
          "elx_mcp_get_api_key(uuid)",
          "elx_mcp_list_projects()"
        ] do
      execute("REVOKE ALL ON FUNCTION #{fn_sig} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{fn_sig} TO PUBLIC")
    end
  end
end
