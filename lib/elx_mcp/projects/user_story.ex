defmodule ElxMcp.Projects.UserStory do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Projects.{Board, Epic, Sprint}
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "user_stories" do
    field :key, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "to_do"
    field :priority, :string, default: "medium"
    field :story_points, :integer
    field :assignee_email, :string
    field :reporter_email, :string
    field :labels, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    belongs_to :epic, Epic
    belongs_to :board, Board
    belongs_to :sprint, Sprint
    has_many :tickets, ElxMcp.Projects.Ticket

    timestamps()
  end

  def changeset(story, attrs) do
    story
    |> cast(attrs, [
      :key,
      :title,
      :description,
      :status,
      :priority,
      :story_points,
      :assignee_email,
      :reporter_email,
      :labels,
      :metadata,
      :project_id,
      :epic_id,
      :board_id,
      :sprint_id
    ])
    |> validate_required([:key, :title, :project_id])
    |> validate_inclusion(:status, Catalog.statuses())
    |> validate_inclusion(:priority, Catalog.priorities())
    |> unique_constraint(:key)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
  end
end
