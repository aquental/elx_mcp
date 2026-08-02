defmodule ElxMcp.Projects.Board do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "boards" do
    field :name, :string
    field :type, :string, default: "scrum"
    field :metadata, :map, default: %{}

    belongs_to :project, Project

    timestamps()
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :type, :metadata])
    |> validate_required([:name])
    |> validate_inclusion(:type, Catalog.board_types())
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end
end
