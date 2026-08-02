defmodule ElxMcp.Collaboration.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "comments" do
    field :commentable_type, :string
    field :commentable_id, :binary_id
    field :author_email, :string
    field :body, :string

    belongs_to :project, Project

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :project_id,
      :commentable_type,
      :commentable_id,
      :author_email,
      :body
    ])
    |> validate_required([
      :project_id,
      :commentable_type,
      :commentable_id,
      :author_email,
      :body
    ])
    |> validate_inclusion(:commentable_type, Catalog.linkable_types())
  end
end
