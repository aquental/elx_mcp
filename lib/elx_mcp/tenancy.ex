defmodule ElxMcp.Tenancy do
  @moduledoc """
  Multi-tenant projects and Jira-style issue key generation.
  """

  import Ecto.Query
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy.Project

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.key])
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def get_project_by_key(key) when is_binary(key) do
    Repo.get_by(Project, key: String.upcase(key))
  end

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Atomically increments `issue_counter` and returns `{project_key}-{n}`.
  """
  def next_issue_key(project_id) do
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
  end
end
