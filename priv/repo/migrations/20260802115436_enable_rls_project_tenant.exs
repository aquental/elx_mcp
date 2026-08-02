defmodule ElxMcp.Repo.Migrations.EnableRlsProjectTenant do
  @moduledoc """
  Enables FORCE ROW LEVEL SECURITY on tenant tables.

  Policies use `current_setting('app.project_id', true)` (NULL-safe missing GUC).
  App must call `ElxMcp.Repo.with_tenant/2` per request/scope.
  Table owner still subject to RLS (FORCE); use `SET LOCAL row_security = off` for admin/seeds.
  """
  use Ecto.Migration

  @tenant_tables ~w(
    projects
    boards
    sprints
    components
    epics
    user_stories
    tickets
    comments
    attachments
    worklogs
    changelogs
    api_keys
  )

  def up do
    enable_project_policy()

    for table <- @tenant_tables -- ["projects"] do
      enable_project_id_policy(table)
    end

    enable_component_links_policy()
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON component_links")
    execute("ALTER TABLE component_links NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE component_links DISABLE ROW LEVEL SECURITY")

    for table <- Enum.reverse(@tenant_tables) do
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end
  end

  defp enable_project_policy do
    execute("ALTER TABLE projects ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE projects FORCE ROW LEVEL SECURITY")
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (id::text = current_setting('app.project_id', true))
      WITH CHECK (id::text = current_setting('app.project_id', true))
    """)
  end

  defp enable_project_id_policy(table) do
    execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")
    execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")

    execute("""
    CREATE POLICY tenant_isolation ON #{table}
      FOR ALL
      USING (project_id::text = current_setting('app.project_id', true))
      WITH CHECK (project_id::text = current_setting('app.project_id', true))
    """)
  end

  defp enable_component_links_policy do
    execute("ALTER TABLE component_links ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE component_links FORCE ROW LEVEL SECURITY")
    execute("DROP POLICY IF EXISTS tenant_isolation ON component_links")

    execute("""
    CREATE POLICY tenant_isolation ON component_links
      FOR ALL
      USING (
        EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id::text = current_setting('app.project_id', true)
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM components c
          WHERE c.id = component_links.component_id
            AND c.project_id::text = current_setting('app.project_id', true)
        )
      )
    """)
  end
end
