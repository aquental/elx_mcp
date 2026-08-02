defmodule ElxMcp.Collaboration do
  @moduledoc """
  Comments, attachments, worklogs, and changelogs (tenant-scoped).

  Writes take `%ElxMcp.Auth.Scope{}` and require `project:write`.
  Entity ids are verified to belong to `scope.project_id` before insert.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias ElxMcp.Auth
  alias ElxMcp.Auth.Scope
  alias ElxMcp.Collaboration.{Attachment, Changelog, Comment, Worklog}
  alias ElxMcp.Projects.{Epic, Ticket, UserStory}
  alias ElxMcp.Repo

  defp tenant(%Scope{project_id: id}, fun), do: Repo.with_tenant(id, fun)

  def create_comment(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope),
           attrs <- Map.new(attrs),
           :ok <-
             ensure_entity_in_project(
               scope.project_id,
               get_attr(attrs, :commentable_type),
               get_attr(attrs, :commentable_id)
             ) do
        %Comment{}
        |> Comment.changeset(attrs)
        |> Ecto.Changeset.put_change(:project_id, scope.project_id)
        |> Ecto.Changeset.put_change(:author_email, scope.actor_email)
        |> Ecto.Changeset.validate_required([:project_id, :author_email])
        |> Repo.insert()
      end
    end)
  end

  def list_comments(%Scope{project_id: project_id} = scope, entity_type, entity_id, opts \\ []) do
    tenant(scope, fn ->
      limit = Keyword.get(opts, :limit, 100) |> min(200)

      Repo.all(
        from c in Comment,
          where:
            c.project_id == ^project_id and c.commentable_type == ^entity_type and
              c.commentable_id == ^entity_id,
          order_by: [asc: c.inserted_at],
          limit: ^limit
      )
    end)
  end

  def create_attachment(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope),
           attrs <- Map.new(attrs),
           :ok <-
             ensure_entity_in_project(
               scope.project_id,
               get_attr(attrs, :attachable_type),
               get_attr(attrs, :attachable_id)
             ) do
        %Attachment{}
        |> Attachment.changeset(attrs)
        |> Ecto.Changeset.put_change(:project_id, scope.project_id)
        |> Ecto.Changeset.put_change(:uploaded_by_email, scope.actor_email)
        |> Ecto.Changeset.validate_required([:project_id])
        |> Repo.insert()
      end
    end)
  end

  def create_worklog(%Scope{} = scope, ticket_id, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope),
           :ok <- ensure_entity_in_project(scope.project_id, "ticket", ticket_id) do
        project_id = scope.project_id

        Multi.new()
        |> Multi.insert(
          :worklog,
          %Worklog{}
          |> Worklog.changeset(Map.new(attrs))
          |> Ecto.Changeset.put_change(:project_id, project_id)
          |> Ecto.Changeset.put_change(:ticket_id, ticket_id)
          |> Ecto.Changeset.put_change(:author_email, scope.actor_email)
          |> Ecto.Changeset.validate_required([:project_id, :ticket_id, :author_email])
        )
        |> Multi.run(:update_ticket, fn _repo, %{worklog: worklog} ->
          # Already under tenant GUC; avoid nested checkout
          {count, _} =
            from(t in Ticket, where: t.id == ^ticket_id and t.project_id == ^project_id)
            |> Repo.update_all(inc: [time_spent_seconds: worklog.time_spent_seconds])

          if count == 1, do: {:ok, worklog.time_spent_seconds}, else: {:error, :not_found}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{worklog: worklog}} -> {:ok, worklog}
          {:error, _step, reason, _} -> {:error, reason}
        end
      end
    end)
  end

  def record_changelog(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope),
           attrs <- Map.new(attrs),
           :ok <-
             ensure_entity_in_project(
               scope.project_id,
               get_attr(attrs, :entity_type),
               get_attr(attrs, :entity_id)
             ) do
        %Changelog{}
        |> Changelog.changeset(attrs)
        |> Ecto.Changeset.put_change(:project_id, scope.project_id)
        |> Ecto.Changeset.put_change(:actor_email, scope.actor_email)
        |> Ecto.Changeset.put_change(:inserted_at, DateTime.utc_now(:microsecond))
        |> Ecto.Changeset.validate_required([:project_id, :inserted_at])
        |> Repo.insert()
      end
    end)
  end

  def list_changelog(%Scope{project_id: project_id} = scope, entity_type, entity_id, opts \\ []) do
    tenant(scope, fn ->
      limit = Keyword.get(opts, :limit, 50) |> min(200) |> max(1)

      Repo.all(
        from c in Changelog,
          where:
            c.project_id == ^project_id and c.entity_type == ^entity_type and
              c.entity_id == ^entity_id,
          order_by: [desc: c.inserted_at],
          limit: ^limit
      )
    end)
  end

  defp ensure_entity_in_project(_project_id, type, id) when is_nil(type) or is_nil(id),
    do: {:error, :invalid_association}

  defp ensure_entity_in_project(project_id, "epic", id),
    do: exists_in_project?(Epic, id, project_id)

  defp ensure_entity_in_project(project_id, "user_story", id),
    do: exists_in_project?(UserStory, id, project_id)

  defp ensure_entity_in_project(project_id, "ticket", id),
    do: exists_in_project?(Ticket, id, project_id)

  defp ensure_entity_in_project(_, _, _), do: {:error, :invalid_association}

  defp exists_in_project?(schema, id, project_id) do
    case Repo.get_by(schema, id: id, project_id: project_id) do
      nil -> {:error, :invalid_association}
      _ -> :ok
    end
  end

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
