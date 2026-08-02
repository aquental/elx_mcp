defmodule ElxMcp.Repo.Migrations.CreateProjectDomain do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :issue_counter, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:key])

    create table(:boards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :type, :string, null: false, default: "scrum"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:boards, [:project_id])
    create unique_index(:boards, [:project_id, :name])

    create table(:sprints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
      add :name, :string, null: false
      add :goal, :text
      add :status, :string, null: false, default: "future"
      add :start_on, :date
      add :end_on, :date
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprints, [:project_id])
    create index(:sprints, [:board_id])
    create index(:sprints, [:status])

    create table(:components, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :lead_email, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:components, [:project_id, :name])

    create table(:epics, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "to_do"
      add :priority, :string, null: false, default: "medium"
      add :owner_email, :string
      add :starts_on, :date
      add :due_on, :date
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:epics, [:key])
    create index(:epics, [:project_id, :status])

    create table(:user_stories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :epic_id, references(:epics, type: :binary_id, on_delete: :nilify_all)
      add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
      add :sprint_id, references(:sprints, type: :binary_id, on_delete: :nilify_all)
      add :key, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "to_do"
      add :priority, :string, null: false, default: "medium"
      add :story_points, :integer
      add :assignee_email, :string
      add :reporter_email, :string
      add :labels, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_stories, [:key])
    create index(:user_stories, [:project_id, :status])
    create index(:user_stories, [:epic_id])
    create index(:user_stories, [:sprint_id])

    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_story_id, references(:user_stories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :parent_ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)
      add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
      add :sprint_id, references(:sprints, type: :binary_id, on_delete: :nilify_all)
      add :key, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :type, :string, null: false, default: "task"
      add :status, :string, null: false, default: "to_do"
      add :priority, :string, null: false, default: "medium"
      add :assignee_email, :string
      add :reporter_email, :string
      add :original_estimate_seconds, :integer
      add :remaining_estimate_seconds, :integer
      add :time_spent_seconds, :integer, null: false, default: 0
      add :labels, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tickets, [:key])
    create index(:tickets, [:project_id, :status])
    create index(:tickets, [:user_story_id])
    create index(:tickets, [:parent_ticket_id])
    create index(:tickets, [:type])
    create index(:tickets, [:sprint_id])

    create table(:component_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      add :linkable_type, :string, null: false
      add :linkable_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:component_links, [:component_id, :linkable_type, :linkable_id],
             name: :component_links_unique
           )

    create index(:component_links, [:linkable_type, :linkable_id])

    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :commentable_type, :string, null: false
      add :commentable_id, :binary_id, null: false
      add :author_email, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comments, [:project_id])
    create index(:comments, [:commentable_type, :commentable_id])

    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :attachable_type, :string, null: false
      add :attachable_id, :binary_id, null: false
      add :filename, :string, null: false
      add :content_type, :string
      add :byte_size, :integer
      add :storage_path, :string, null: false
      add :uploaded_by_email, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:attachments, [:project_id])
    create index(:attachments, [:attachable_type, :attachable_id])

    create table(:worklogs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false
      add :author_email, :string, null: false
      add :time_spent_seconds, :integer, null: false
      add :started_at, :utc_datetime_usec
      add :note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:worklogs, [:project_id])
    create index(:worklogs, [:ticket_id])

    create table(:changelogs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :entity_type, :string, null: false
      add :entity_id, :binary_id, null: false
      add :actor_email, :string
      add :field, :string, null: false
      add :old_value, :text
      add :new_value, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:changelogs, [:project_id])
    create index(:changelogs, [:entity_type, :entity_id])

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :email, :string, null: false
      add :key_hash, :binary, null: false
      add :key_prefix, :string, null: false
      add :name, :string
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :scopes, {:array, :string}, null: false, default: ["project:read"]
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:project_id, :email])
    create index(:api_keys, [:revoked_at])
  end
end
