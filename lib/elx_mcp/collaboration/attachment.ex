defmodule ElxMcp.Collaboration.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "attachments" do
    field :attachable_type, :string
    field :attachable_id, :binary_id
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :storage_path, :string
    field :uploaded_by_email, :string

    belongs_to :project, Project

    timestamps()
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :attachable_type,
      :attachable_id,
      :filename,
      :content_type,
      :byte_size,
      :storage_path,
      :uploaded_by_email
    ])
    # :project_id set via put_change in context
    |> validate_required([
      :attachable_type,
      :attachable_id,
      :filename,
      :storage_path
    ])
    |> validate_inclusion(:attachable_type, Catalog.linkable_types())
    |> foreign_key_constraint(:project_id)
  end
end
