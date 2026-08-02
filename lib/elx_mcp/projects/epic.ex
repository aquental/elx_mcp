defmodule ElxMcp.Projects.Epic do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Catalog
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "epics" do
    field :key, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "to_do"
    field :priority, :string, default: "medium"
    field :owner_email, :string
    field :starts_on, :date
    field :due_on, :date
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    has_many :user_stories, ElxMcp.Projects.UserStory

    timestamps()
  end

  def changeset(epic, attrs) do
    epic
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :owner_email,
      :starts_on,
      :due_on,
      :metadata
    ])
    # :key and :project_id set via put_change in context (not mass-assigned)
    |> validate_required([:title])
    |> validate_inclusion(:status, Catalog.statuses())
    |> validate_inclusion(:priority, Catalog.priorities())
    |> unique_constraint(:key)
    |> foreign_key_constraint(:project_id)
  end
end
