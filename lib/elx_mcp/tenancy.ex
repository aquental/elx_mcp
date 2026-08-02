defmodule ElxMcp.Tenancy do
  @moduledoc """
  Multi-tenant projects and Jira-style issue key generation.

  Cross-tenant admin reads use SECURITY DEFINER functions (not tenant HTTP surface):
  `list_projects/0`, `get_project/1`, `get_project_by_key/1`.

  Writes / counters use `Repo.with_tenant/2` (transaction-local RLS GUC).
  """

  import Ecto.Query
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy.Project

  @doc """
  Lists all projects via SECURITY DEFINER (admin/bootstrap).
  """
  def list_projects do
    result = Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM elx_mcp_list_projects()", [])

    Enum.map(result.rows, fn row ->
      load_project_struct(Map.new(Enum.zip(result.columns, row)))
    end)
  end

  def get_project!(id) do
    case get_project(id) do
      nil -> raise Ecto.NoResultsError, queryable: Project
      project -> project
    end
  end

  @doc """
  Loads a project by id via SECURITY DEFINER. Returns `nil` if missing.
  """
  def get_project(id) when is_binary(id) do
    result =
      Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM elx_mcp_get_project($1::uuid)", [
        uuid_param(id)
      ])

    case result.rows do
      [row] -> load_project_struct(Map.new(Enum.zip(result.columns, row)))
      _ -> nil
    end
  end

  defp uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  @doc """
  Loads a project by key via SECURITY DEFINER. Returns `nil` if missing.
  """
  def get_project_by_key(key) when is_binary(key) do
    result =
      Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM elx_mcp_get_project_by_key($1)", [key])

    case result.rows do
      [row] -> load_project_struct(Map.new(Enum.zip(result.columns, row)))
      _ -> nil
    end
  end

  def create_project(attrs) do
    id = Ecto.UUID.generate()

    changeset =
      %Project{id: id}
      |> Project.changeset(attrs)

    # RLS: GUC must match projects.id for INSERT.
    # On constraint errors, rollback with the changeset so callers get
    # {:error, %Ecto.Changeset{}} instead of a bare :rollback.
    Repo.with_tenant(id, fn ->
      case Repo.insert(changeset) do
        {:ok, project} -> {:ok, project}
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Atomically increments `issue_counter` and returns `{project_key}-{n}`.
  """
  def next_issue_key(project_id) do
    Repo.with_tenant(project_id, fn ->
      # Already inside a transaction from with_tenant; nested transaction = savepoint.
      Repo.transaction(fn ->
        project =
          Project
          |> where([p], p.id == ^project_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        n = project.issue_counter + 1

        project
        |> Ecto.Changeset.change(issue_counter: n)
        |> Repo.update!()

        "#{project.key}-#{n}"
      end)
    end)
  end

  defp load_project_struct(map) when is_map(map) do
    # Repo.load expects dump format for :binary_id (16-byte UUID), not strings.
    normalized =
      map
      |> normalize_row_keys()
      |> Map.update("id", nil, &dump_uuid/1)
      |> Map.update("issue_counter", 0, fn v -> v || 0 end)
      |> Map.update("metadata", %{}, fn m -> m || %{} end)

    Repo.load(Project, normalized)
  end

  defp normalize_row_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp dump_uuid(nil), do: nil

  defp dump_uuid(str) when is_binary(str) and byte_size(str) == 36 do
    case Ecto.UUID.dump(str) do
      {:ok, bin} -> bin
      :error -> str
    end
  end

  defp dump_uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin
  defp dump_uuid(other), do: other
end
