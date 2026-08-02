defmodule ElxMcp.Collaboration.Worklog do
  use Ecto.Schema
  import Ecto.Changeset

  alias ElxMcp.Projects.Ticket
  alias ElxMcp.Tenancy.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "worklogs" do
    field :author_email, :string
    field :time_spent_seconds, :integer
    field :started_at, :utc_datetime_usec
    field :note, :string

    belongs_to :project, Project
    belongs_to :ticket, Ticket

    timestamps()
  end

  def changeset(worklog, attrs) do
    worklog
    |> cast(attrs, [
      :time_spent_seconds,
      :started_at,
      :note
    ])
    # :project_id, :ticket_id, :author_email set via put_change in context
    |> validate_required([:time_spent_seconds])
    |> validate_number(:time_spent_seconds, greater_than: 0)
    |> foreign_key_constraint(:project_id)
  end
end
