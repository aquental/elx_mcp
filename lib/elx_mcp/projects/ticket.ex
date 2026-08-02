defmodule ElxMcp.Projects.Ticket do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Projects.{Board, Sprint, UserStory}
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tickets" do
    field :key, :string
    field :title, :string
    field :description, :string
    field :type, :string, default: "task"
    field :status, :string, default: "to_do"
    field :priority, :string, default: "medium"
    field :assignee_email, :string
    field :reporter_email, :string
    field :original_estimate_seconds, :integer
    field :remaining_estimate_seconds, :integer
    field :time_spent_seconds, :integer, default: 0
    field :labels, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    belongs_to :user_story, UserStory
    belongs_to :parent_ticket, __MODULE__
    belongs_to :board, Board
    belongs_to :sprint, Sprint
    has_many :subtasks, __MODULE__, foreign_key: :parent_ticket_id
    has_many :worklogs, ElxMcp.Collaboration.Worklog

    timestamps()
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :key,
      :title,
      :description,
      :type,
      :status,
      :priority,
      :assignee_email,
      :reporter_email,
      :original_estimate_seconds,
      :remaining_estimate_seconds,
      :time_spent_seconds,
      :labels,
      :metadata,
      :project_id,
      :user_story_id,
      :parent_ticket_id,
      :board_id,
      :sprint_id
    ])
    |> validate_required([:key, :title, :project_id, :user_story_id])
    |> validate_inclusion(:type, Catalog.ticket_types())
    |> validate_inclusion(:status, Catalog.statuses())
    |> validate_inclusion(:priority, Catalog.priorities())
    |> validate_subtask_parent()
    |> unique_constraint(:key)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_story_id)
    |> foreign_key_constraint(:parent_ticket_id)
  end

  defp validate_subtask_parent(changeset) do
    type = get_field(changeset, :type)
    parent_id = get_field(changeset, :parent_ticket_id)

    cond do
      type == "subtask" and is_nil(parent_id) ->
        add_error(changeset, :parent_ticket_id, "is required for subtasks")

      true ->
        changeset
    end
  end
end
