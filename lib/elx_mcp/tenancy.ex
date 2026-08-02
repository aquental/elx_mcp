defmodule ElxMcp.Tenancy do
  @moduledoc """
  Multi-tenant projects and Jira-style issue key generation.
  """

  import Ecto.Query
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy.Project

  def list_projects do
    {:ok, projects} =
      Repo.with_bypass(fn ->
        Repo.all(from p in Project, order_by: [asc: p.key])
      end)

    projects
  end

  def get_project!(id) do
    {:ok, project} =
      Repo.with_bypass(fn ->
        Repo.get!(Project, id)
      end)

    project
  end

  def get_project_by_key(key) when is_binary(key) do
    {:ok, project} =
      Repo.with_bypass(fn ->
        Repo.get_by(Project, key: String.upcase(key))
      end)

    project
  end

  def create_project(attrs) do
    id = Ecto.UUID.generate()

    changeset =
      %Project{id: id}
      |> Project.changeset(attrs)

    # RLS: GUC must match projects.id for INSERT
    Repo.with_tenant(id, fn ->
      Repo.insert(changeset)
    end)
  end

  @doc """
  Atomically increments `issue_counter` and returns `{project_key}-{n}`.
  """
  def next_issue_key(project_id) do
    Repo.with_tenant(project_id, fn ->
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
end
