defmodule ElxMcp.Collaboration.Changelog do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "changelogs" do
    field :entity_type, :string
    field :entity_id, :binary_id
    field :actor_email, :string
    field :field, :string
    field :old_value, :string
    field :new_value, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :project, Project
  end

  def changeset(changelog, attrs) do
    changelog
    |> cast(attrs, [
      :project_id,
      :entity_type,
      :entity_id,
      :actor_email,
      :field,
      :old_value,
      :new_value,
      :inserted_at
    ])
    |> validate_required([:project_id, :entity_type, :entity_id, :field, :inserted_at])
    |> validate_inclusion(:entity_type, Catalog.entity_types())
  end
end
