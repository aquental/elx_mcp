defmodule ElxMcp.Projects.Sprint do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Projects.Board
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sprints" do
    field :name, :string
    field :goal, :string
    field :status, :string, default: "future"
    field :start_on, :date
    field :end_on, :date
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    belongs_to :board, Board

    timestamps()
  end

  def changeset(sprint, attrs) do
    sprint
    |> cast(attrs, [:name, :goal, :status, :start_on, :end_on, :metadata, :project_id, :board_id])
    |> validate_required([:name, :project_id])
    |> validate_inclusion(:status, Catalog.sprint_statuses())
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:board_id)
  end
end
