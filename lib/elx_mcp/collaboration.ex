defmodule ElxMcp.Collaboration do
  @moduledoc """
  Comments, attachments, worklogs, and changelogs (tenant-scoped).
  """

  import Ecto.Query
  alias Ecto.Multi
  alias ElxMcp.Auth.Scope
  alias ElxMcp.Collaboration.{Attachment, Changelog, Comment, Worklog}
  alias ElxMcp.Projects.Ticket
  alias ElxMcp.Repo

  def create_comment(project_id, attrs) do
    %Comment{}
    |> Comment.changeset(Map.put(Map.new(attrs), :project_id, project_id))
    |> Repo.insert()
  end

  def list_comments(%Scope{project_id: project_id}, entity_type, entity_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100) |> min(200)

    Repo.all(
      from c in Comment,
        where:
          c.project_id == ^project_id and c.commentable_type == ^entity_type and
            c.commentable_id == ^entity_id,
        order_by: [asc: c.inserted_at],
        limit: ^limit
    )
  end

  def create_attachment(project_id, attrs) do
    %Attachment{}
    |> Attachment.changeset(Map.put(Map.new(attrs), :project_id, project_id))
    |> Repo.insert()
  end

  def create_worklog(project_id, ticket_id, attrs) do
    Multi.new()
    |> Multi.insert(
      :worklog,
      Worklog.changeset(
        %Worklog{},
        Map.new(attrs)
        |> Map.put(:project_id, project_id)
        |> Map.put(:ticket_id, ticket_id)
      )
    )
    |> Multi.run(:update_ticket, fn repo, %{worklog: worklog} ->
      {1, _} =
        from(t in Ticket, where: t.id == ^ticket_id and t.project_id == ^project_id)
        |> repo.update_all(inc: [time_spent_seconds: worklog.time_spent_seconds])

      {:ok, worklog.time_spent_seconds}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{worklog: worklog}} -> {:ok, worklog}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  def record_changelog(project_id, attrs) do
    params =
      Map.new(attrs)
      |> Map.put(:project_id, project_id)
      |> Map.put_new(:inserted_at, DateTime.utc_now(:microsecond))

    %Changelog{}
    |> Changelog.changeset(params)
    |> Repo.insert()
  end

  def list_changelog(%Scope{project_id: project_id}, entity_type, entity_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from c in Changelog,
        where:
          c.project_id == ^project_id and c.entity_type == ^entity_type and
            c.entity_id == ^entity_id,
        order_by: [desc: c.inserted_at],
        limit: ^limit
    )
  end
end
