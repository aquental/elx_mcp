defmodule ElxMcp.Repo.Migrations.EnablePgTrgmSearch do
  use Ecto.Migration

  # Enables pg_trgm + GIN on titles. If CREATE EXTENSION fails (no superuser),
  # run it once as admin; ILIKE title search still works without the index.

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX IF NOT EXISTS epics_title_trgm_idx
    ON epics USING gin (title gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS user_stories_title_trgm_idx
    ON user_stories USING gin (title gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS tickets_title_trgm_idx
    ON tickets USING gin (title gin_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS tickets_title_trgm_idx")
    execute("DROP INDEX IF EXISTS user_stories_title_trgm_idx")
    execute("DROP INDEX IF EXISTS epics_title_trgm_idx")
    # Extension left in place (may be used by other DBs/apps)
  end
end
