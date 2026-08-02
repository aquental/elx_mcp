defmodule ElxMcp.Tenancy.Project do
  use Ecto.Schema
  import Ecto.Changeset

  # autogenerate false when caller pre-assigns id for RLS GUC alignment (see Tenancy.create_project)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projects" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :issue_counter, :integer, default: 0
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:key, :name, :description, :metadata])
    |> update_change(:key, &normalize_key/1)
    |> validate_required([:key, :name])
    |> validate_length(:key, min: 2, max: 10)
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9]+$/,
      message: "must be 2-10 uppercase letters/digits starting with a letter"
    )
    |> unique_constraint(:key)
  end

  defp normalize_key(nil), do: nil
  defp normalize_key(key) when is_binary(key), do: String.upcase(String.trim(key))
end
