defmodule ElxMcp.Repo.Migrations.AddListQueryIndexes do
  use Ecto.Migration

  def change do
    create index(:epics, [:project_id, :updated_at])
    create index(:user_stories, [:project_id, :updated_at])
    create index(:tickets, [:project_id, :updated_at])
    create index(:user_stories, [:project_id, :assignee_email])
    create index(:tickets, [:project_id, :assignee_email])
  end
end
