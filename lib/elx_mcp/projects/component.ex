defmodule ElxMcp.Projects.Component do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "components" do
    field :name, :string
    field :description, :string
    field :lead_email, :string

    belongs_to :project, Project

    timestamps()
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [:name, :description, :lead_email])
    |> validate_required([:name])
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end
end
