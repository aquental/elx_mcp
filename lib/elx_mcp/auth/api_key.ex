defmodule ElxMcp.Auth.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_keys" do
    field :email, :string
    field :key_hash, :binary
    field :key_prefix, :string
    field :name, :string
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :scopes, {:array, :string}, default: ["project:read"]
    field :metadata, :map, default: %{}

    belongs_to :project, Project

    timestamps()
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:email, :name, :scopes, :metadata])
    |> validate_required([:email])
    |> update_change(:email, &String.downcase(String.trim(&1)))
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_subset(:scopes, ElxMcp.Catalog.scopes())
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:project_id)
  end
end
