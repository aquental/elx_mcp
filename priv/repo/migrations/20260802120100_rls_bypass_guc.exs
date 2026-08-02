defmodule ElxMcp.Repo.Migrations.RlsBypassGuc do
  @moduledoc """
  Policies allow either matching `app.project_id` or explicit `app.bypass_rls=on`
  (session GUC set only by trusted app code via Repo.with_bypass/1).

  Needed because non-superusers cannot `SET row_security = off` under FORCE RLS.
  """
  use Ecto.Migration

  @tables_with_project_id ~w(
    boards sprints components epics user_stories tickets
    comments attachments worklogs changelogs api_keys
  )

  def up do
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

  def down do
    # Restore strict policies from previous migration shape
    execute("DROP POLICY IF EXISTS tenant_isolation ON projects")

    execute("""
    CREATE POLICY tenant_isolation ON projects
      FOR ALL
      USING (id::text = current_setting('app.project_id', true))
      WITH CHECK (id::text = current_setting('app.project_id', true))
    """)

    for table <- @tables_with_project_id do
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table}")

      execute("""
      CREATE POLICY tenant_isolation ON #{table}
        FOR ALL
        USING (project_id::text = current_setting('app.project_id', true))
        WITH CHECK (project_id::text = current_setting('app.project_id', true))
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
