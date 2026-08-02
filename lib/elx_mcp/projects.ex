defmodule ElxMcp.Projects do
  @moduledoc """
  Project work items: epics, stories, tickets, boards, sprints, components.

  **Writes** take `%ElxMcp.Auth.Scope{}` and require `project:write`.
  **Reads** take `%Scope{}` with tenant isolation via pinned `project_id`.

  `get_*` preloads at most 50 child associations by default (`:child_limit`, max 200).
  Full child enumeration uses `list_*` with filters.
  """

  import Ecto.Query
  alias ElxMcp.Auth
  alias ElxMcp.Auth.Scope
  alias ElxMcp.Projects.{Board, Component, Epic, Sprint, Ticket, UserStory}
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy

  @default_child_limit 50
  @max_child_limit 200

  defp tenant(%Scope{project_id: id}, fun), do: Repo.with_tenant(id, fun)

  defp tenant(project_id, fun) when is_binary(project_id), do: Repo.with_tenant(project_id, fun)

  # --- Boards / Sprints / Components ---

  def create_board(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_board(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_board(project_id, attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> Ecto.Changeset.validate_required([:project_id])
    |> Repo.insert()
  end

  def list_boards(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      limit = Keyword.get(opts, :limit, 100) |> min(200)

      Repo.all(
        from b in Board,
          where: b.project_id == ^project_id,
          order_by: [asc: b.name],
          limit: ^limit
      )
    end)
  end

  def create_sprint(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_sprint(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_sprint(project_id, attrs) do
    attrs = Map.new(attrs)

    with :ok <-
           ensure_same_project(
             Board,
             Map.get(attrs, :board_id) || Map.get(attrs, "board_id"),
             project_id
           ) do
      %Sprint{}
      |> Sprint.changeset(attrs)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.validate_required([:project_id])
      |> Repo.insert()
    end
  end

  def list_sprints(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      status = Keyword.get(opts, :status)
      limit = Keyword.get(opts, :limit, 100) |> min(200)

      Sprint
      |> where([s], s.project_id == ^project_id)
      |> maybe_filter_status(status)
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    end)
  end

  def get_sprint(%Scope{project_id: project_id} = scope, id_or_name) when is_binary(id_or_name) do
    tenant(scope, fn ->
      query =
        case Ecto.UUID.cast(id_or_name) do
          {:ok, id} -> from s in Sprint, where: s.project_id == ^project_id and s.id == ^id
          :error -> from s in Sprint, where: s.project_id == ^project_id and s.name == ^id_or_name
        end

      case Repo.one(query) do
        nil -> {:error, :not_found}
        sprint -> {:ok, sprint}
      end
    end)
  end

  def create_component(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_component(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_component(project_id, attrs) do
    %Component{}
    |> Component.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> Ecto.Changeset.validate_required([:project_id])
    |> Repo.insert()
  end

  # --- Epics ---

  def create_epic(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_epic(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_epic(project_id, attrs) do
    with {:ok, key} <- Tenancy.next_issue_key(project_id) do
      %Epic{}
      |> Epic.changeset(attrs)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.put_change(:key, key)
      |> Ecto.Changeset.validate_required([:project_id, :key])
      |> Repo.insert()
    end
  end

  def list_epics(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      Epic
      |> where([e], e.project_id == ^project_id)
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_priority(Keyword.get(opts, :priority))
      |> order_by([e], desc: e.updated_at)
      |> maybe_limit(Keyword.get(opts, :limit, 50))
      |> Repo.all()
    end)
  end

  def get_epic(%Scope{project_id: project_id} = scope, key, opts \\ []) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(from e in Epic, where: e.project_id == ^project_id and e.key == ^key) do
        nil ->
          {:error, :not_found}

        epic ->
          n = child_limit(opts)

          stories =
            from(us in UserStory,
              where: us.epic_id == ^epic.id and us.project_id == ^project_id,
              order_by: [desc: us.updated_at],
              limit: ^n
            )
            |> Repo.all()

          {:ok, %{epic | user_stories: stories}}
      end
    end)
  end

  @doc "Resolve epic id by key without preloads (for list filters)."
  def get_epic_id(%Scope{project_id: project_id} = scope, key) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(
             from e in Epic,
               where: e.project_id == ^project_id and e.key == ^key,
               select: e.id
           ) do
        nil -> {:error, :not_found}
        id -> {:ok, id}
      end
    end)
  end

  # --- User stories ---

  def create_user_story(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_user_story(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_user_story(project_id, attrs) do
    attrs = Map.new(attrs)

    with {:ok, key} <- Tenancy.next_issue_key(project_id),
         :ok <- ensure_same_project(Epic, get_attr(attrs, :epic_id), project_id),
         :ok <- ensure_same_project(Board, get_attr(attrs, :board_id), project_id),
         :ok <- ensure_same_project(Sprint, get_attr(attrs, :sprint_id), project_id) do
      %UserStory{}
      |> UserStory.changeset(attrs)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.put_change(:key, key)
      |> Ecto.Changeset.validate_required([:project_id, :key])
      |> Repo.insert()
    end
  end

  def list_user_stories(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      UserStory
      |> where([s], s.project_id == ^project_id)
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_epic_id(Keyword.get(opts, :epic_id))
      |> maybe_filter_sprint_id(Keyword.get(opts, :sprint_id))
      |> maybe_filter_assignee(Keyword.get(opts, :assignee_email))
      |> order_by([s], desc: s.updated_at)
      |> maybe_limit(Keyword.get(opts, :limit, 50))
      |> Repo.all()
    end)
  end

  def get_user_story(%Scope{project_id: project_id} = scope, key, opts \\ []) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(from s in UserStory, where: s.project_id == ^project_id and s.key == ^key) do
        nil ->
          {:error, :not_found}

        story ->
          n = child_limit(opts)
          epic = if story.epic_id, do: Repo.get_by(Epic, id: story.epic_id, project_id: project_id)

          tickets =
            from(t in Ticket,
              where: t.user_story_id == ^story.id and t.project_id == ^project_id,
              order_by: [desc: t.updated_at],
              limit: ^n
            )
            |> Repo.all()

          {:ok, %{story | epic: epic, tickets: tickets}}
      end
    end)
  end

  @doc "Resolve user story id by key without preloads."
  def get_user_story_id(%Scope{project_id: project_id} = scope, key) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(
             from s in UserStory,
               where: s.project_id == ^project_id and s.key == ^key,
               select: s.id
           ) do
        nil -> {:error, :not_found}
        id -> {:ok, id}
      end
    end)
  end

  # --- Tickets ---

  def create_ticket(%Scope{} = scope, attrs) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_create_ticket(scope.project_id, attrs)
      end
    end)
  end

  defp do_create_ticket(project_id, attrs) do
    attrs = Map.new(attrs)

    with {:ok, key} <- Tenancy.next_issue_key(project_id),
         :ok <- ensure_same_project(UserStory, get_attr(attrs, :user_story_id), project_id),
         :ok <- ensure_same_project(Ticket, get_attr(attrs, :parent_ticket_id), project_id),
         :ok <- ensure_same_project(Board, get_attr(attrs, :board_id), project_id),
         :ok <- ensure_same_project(Sprint, get_attr(attrs, :sprint_id), project_id),
         :ok <- validate_parent_cycle(project_id, get_attr(attrs, :parent_ticket_id), nil) do
      %Ticket{}
      |> Ticket.changeset(attrs)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.put_change(:key, key)
      |> Ecto.Changeset.validate_required([:project_id, :key])
      |> Repo.insert()
    end
  end

  @doc """
  Updates a ticket's parent. Used for hierarchy changes and cycle detection tests.
  Requires `project:write`.
  """
  def update_ticket_parent(%Scope{} = scope, ticket_id, parent_ticket_id) do
    tenant(scope, fn ->
      with :ok <- Auth.authorize_write(scope) do
        do_update_ticket_parent(scope.project_id, ticket_id, parent_ticket_id)
      end
    end)
  end

  defp do_update_ticket_parent(project_id, ticket_id, parent_ticket_id) do
    with :ok <- ensure_same_project(Ticket, parent_ticket_id, project_id),
         :ok <- validate_parent_cycle(project_id, parent_ticket_id, ticket_id) do
      case Repo.get_by(Ticket, id: ticket_id, project_id: project_id) do
        nil ->
          {:error, :not_found}

        ticket ->
          ticket
          |> Ecto.Changeset.change(%{parent_ticket_id: parent_ticket_id, type: "subtask"})
          |> Repo.update()
      end
    end
  end

  @doc "Atomically increment ticket time_spent_seconds (used by worklogs)."
  def increment_time_spent(project_id, ticket_id, seconds)
      when is_integer(seconds) and seconds > 0 do
    tenant(project_id, fn ->
      {count, _} =
        from(t in Ticket, where: t.id == ^ticket_id and t.project_id == ^project_id)
        |> Repo.update_all(inc: [time_spent_seconds: seconds])

      if count == 1, do: :ok, else: {:error, :not_found}
    end)
  end

  def list_tickets(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      Ticket
      |> where([t], t.project_id == ^project_id)
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_type(Keyword.get(opts, :type))
      |> maybe_filter_story_id(Keyword.get(opts, :user_story_id))
      |> maybe_filter_sprint_id(Keyword.get(opts, :sprint_id))
      |> maybe_filter_assignee(Keyword.get(opts, :assignee_email))
      |> order_by([t], desc: t.updated_at)
      |> maybe_limit(Keyword.get(opts, :limit, 50))
      |> Repo.all()
    end)
  end

  def get_ticket(%Scope{project_id: project_id} = scope, key, opts \\ []) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(from t in Ticket, where: t.project_id == ^project_id and t.key == ^key) do
        nil ->
          {:error, :not_found}

        ticket ->
          n = child_limit(opts)

          story =
            if ticket.user_story_id,
              do: Repo.get_by(UserStory, id: ticket.user_story_id, project_id: project_id)

          subtasks =
            from(t in Ticket,
              where: t.parent_ticket_id == ^ticket.id and t.project_id == ^project_id,
              order_by: [desc: t.updated_at],
              limit: ^n
            )
            |> Repo.all()

          {:ok, %{ticket | user_story: story, subtasks: subtasks}}
      end
    end)
  end

  @doc "Resolve ticket id by key without preloads."
  def get_ticket_id(%Scope{project_id: project_id} = scope, key) when is_binary(key) do
    tenant(scope, fn ->
      case Repo.one(
             from t in Ticket,
               where: t.project_id == ^project_id and t.key == ^key,
               select: t.id
           ) do
        nil -> {:error, :not_found}
        id -> {:ok, id}
      end
    end)
  end

  @doc """
  Search work items with fast paths:

  1. Exact key (case-insensitive)
  2. Prefix key (`q%`, no leading `%`)
  3. Title substring (ILIKE; uses `pg_trgm` GIN when available)
  4. Description only when `opts[:include_description] == true`

  Hard cap `min(limit, 50)`.
  """
  def search_work_items(%Scope{project_id: project_id} = scope, q, opts \\ []) when is_binary(q) do
    tenant(scope, fn ->
      q = String.trim(q)
      limit = Keyword.get(opts, :limit, 25) |> min(50)
      include_desc? = Keyword.get(opts, :include_description, false)

      if q == "" do
        []
      else
        escaped = escape_like(q)
        exact_key = String.upcase(q)
        prefix = escaped <> "%"
        title_pattern = "%" <> escaped <> "%"

        exact = search_exact_key(project_id, exact_key, limit)
        remaining = limit - length(exact)

        prefix_hits =
          if remaining > 0 do
            search_prefix_key(project_id, prefix, remaining, MapSet.new(Enum.map(exact, & &1.key)))
          else
            []
          end

        remaining = limit - length(exact) - length(prefix_hits)
        known = MapSet.new(Enum.map(exact ++ prefix_hits, & &1.key))

        title_hits =
          if remaining > 0 do
            search_title(project_id, title_pattern, remaining, known, include_desc?)
          else
            []
          end

        exact ++ prefix_hits ++ title_hits
      end
    end)
  end

  @doc """
  Aggregated project status: counts by status + recent items.
  """
  def status_summary(%Scope{project_id: project_id} = scope, opts \\ []) do
    tenant(scope, fn ->
      recent_limit = Keyword.get(opts, :recent_limit, 10) |> min(50)

      %{
        project_id: project_id,
        epics_by_status: count_by_status(Epic, project_id),
        stories_by_status: count_by_status(UserStory, project_id),
        tickets_by_status: count_by_status(Ticket, project_id),
        recent: recent_items(project_id, recent_limit),
        in_review: recent_tickets(project_id, "in_review", recent_limit)
      }
    end)
  end

  # --- Search helpers ---

  defp search_exact_key(project_id, key, limit) do
    epics =
      from(e in Epic,
        where: e.project_id == ^project_id and e.key == ^key,
        select: %{type: "epic", key: e.key, title: e.title, status: e.status},
        limit: ^limit
      )
      |> Repo.all()

    stories =
      from(s in UserStory,
        where: s.project_id == ^project_id and s.key == ^key,
        select: %{type: "user_story", key: s.key, title: s.title, status: s.status},
        limit: ^limit
      )
      |> Repo.all()

    tickets =
      from(t in Ticket,
        where: t.project_id == ^project_id and t.key == ^key,
        select: %{type: "ticket", key: t.key, title: t.title, status: t.status},
        limit: ^limit
      )
      |> Repo.all()

    (epics ++ stories ++ tickets) |> Enum.take(limit)
  end

  defp search_prefix_key(project_id, prefix, limit, exclude_keys) do
    epics =
      from(e in Epic,
        where: e.project_id == ^project_id and ilike(e.key, ^prefix),
        select: %{type: "epic", key: e.key, title: e.title, status: e.status},
        limit: ^limit
      )
      |> Repo.all()

    stories =
      from(s in UserStory,
        where: s.project_id == ^project_id and ilike(s.key, ^prefix),
        select: %{type: "user_story", key: s.key, title: s.title, status: s.status},
        limit: ^limit
      )
      |> Repo.all()

    tickets =
      from(t in Ticket,
        where: t.project_id == ^project_id and ilike(t.key, ^prefix),
        select: %{type: "ticket", key: t.key, title: t.title, status: t.status},
        limit: ^limit
      )
      |> Repo.all()

    (epics ++ stories ++ tickets)
    |> Enum.reject(&MapSet.member?(exclude_keys, &1.key))
    |> Enum.take(limit)
  end

  defp search_title(project_id, pattern, limit, exclude_keys, include_desc?) do
    epics =
      from(e in Epic,
        where:
          e.project_id == ^project_id and
            (ilike(e.title, ^pattern) or
               (^include_desc? and ilike(e.description, ^pattern))),
        select: %{type: "epic", key: e.key, title: e.title, status: e.status},
        limit: ^limit
      )
      |> Repo.all()

    stories =
      from(s in UserStory,
        where:
          s.project_id == ^project_id and
            (ilike(s.title, ^pattern) or
               (^include_desc? and ilike(s.description, ^pattern))),
        select: %{type: "user_story", key: s.key, title: s.title, status: s.status},
        limit: ^limit
      )
      |> Repo.all()

    tickets =
      from(t in Ticket,
        where:
          t.project_id == ^project_id and
            (ilike(t.title, ^pattern) or
               (^include_desc? and ilike(t.description, ^pattern))),
        select: %{type: "ticket", key: t.key, title: t.title, status: t.status},
        limit: ^limit
      )
      |> Repo.all()

    (epics ++ stories ++ tickets)
    |> Enum.reject(&MapSet.member?(exclude_keys, &1.key))
    |> Enum.take(limit)
  end

  # --- Helpers ---

  defp child_limit(opts) do
    Keyword.get(opts, :child_limit, @default_child_limit)
    |> min(@max_child_limit)
    |> max(1)
  end

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp count_by_status(schema, project_id) do
    from(r in schema,
      where: r.project_id == ^project_id,
      group_by: r.status,
      select: {r.status, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp recent_items(project_id, limit) do
    epics = recent_rows(Epic, "epic", project_id, limit)
    stories = recent_rows(UserStory, "user_story", project_id, limit)
    tickets = recent_rows(Ticket, "ticket", project_id, limit)

    (epics ++ stories ++ tickets)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp recent_rows(schema, type, project_id, limit) do
    from(r in schema,
      where: r.project_id == ^project_id,
      order_by: [desc: r.updated_at],
      limit: ^limit,
      select: %{
        type: ^type,
        key: r.key,
        title: r.title,
        status: r.status,
        updated_at: r.updated_at
      }
    )
    |> Repo.all()
  end

  defp recent_tickets(project_id, status, limit) do
    from(t in Ticket,
      where: t.project_id == ^project_id and t.status == ^status,
      order_by: [desc: t.updated_at],
      limit: ^limit,
      select: %{
        type: "ticket",
        key: t.key,
        title: t.title,
        status: t.status,
        updated_at: t.updated_at
      }
    )
    |> Repo.all()
  end

  defp ensure_same_project(_schema, nil, _project_id), do: :ok

  defp ensure_same_project(schema, id, project_id) do
    case Repo.get_by(schema, id: id, project_id: project_id) do
      nil -> {:error, :invalid_association}
      _ -> :ok
    end
  end

  defp validate_parent_cycle(_project_id, nil, _self_id), do: :ok

  defp validate_parent_cycle(project_id, parent_id, self_id) do
    if walk_creates_cycle?(project_id, parent_id, self_id, MapSet.new()) do
      {:error, :cycle_detected}
    else
      :ok
    end
  end

  defp walk_creates_cycle?(_project_id, nil, _self_id, _seen), do: false

  defp walk_creates_cycle?(project_id, parent_id, self_id, seen) do
    cond do
      not is_nil(self_id) and parent_id == self_id ->
        true

      MapSet.member?(seen, parent_id) ->
        true

      true ->
        case Repo.get_by(Ticket, id: parent_id, project_id: project_id) do
          nil ->
            false

          %Ticket{parent_ticket_id: next} ->
            walk_creates_cycle?(project_id, next, self_id, MapSet.put(seen, parent_id))
        end
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp maybe_filter_priority(query, nil), do: query
  defp maybe_filter_priority(query, priority), do: where(query, [r], r.priority == ^priority)

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [r], r.type == ^type)

  defp maybe_filter_epic_id(query, nil), do: query
  defp maybe_filter_epic_id(query, epic_id), do: where(query, [r], r.epic_id == ^epic_id)

  defp maybe_filter_story_id(query, nil), do: query

  defp maybe_filter_story_id(query, story_id),
    do: where(query, [r], r.user_story_id == ^story_id)

  defp maybe_filter_sprint_id(query, nil), do: query
  defp maybe_filter_sprint_id(query, sprint_id), do: where(query, [r], r.sprint_id == ^sprint_id)

  defp maybe_filter_assignee(query, nil), do: query

  defp maybe_filter_assignee(query, email),
    do: where(query, [r], r.assignee_email == ^email)

  defp maybe_limit(query, nil), do: limit(query, ^50)

  defp maybe_limit(query, limit) when is_integer(limit) do
    limit(query, ^min(limit, 200))
  end

  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
