defmodule ElxMcp.Projects.ComponentLink do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Projects.Component

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "component_links" do
    field :linkable_type, :string
    field :linkable_id, :binary_id

    belongs_to :component, Component

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:component_id, :linkable_type, :linkable_id])
    |> validate_required([:component_id, :linkable_type, :linkable_id])
    |> validate_inclusion(:linkable_type, Catalog.linkable_types())
    |> unique_constraint([:component_id, :linkable_type, :linkable_id],
      name: :component_links_unique
    )
  end
end
