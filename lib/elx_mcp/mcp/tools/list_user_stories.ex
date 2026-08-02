defmodule ElxMcp.MCP.Tools.ListUserStories do
  @moduledoc """
  List user stories / Listar user stories do projeto.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :status, :string
    field :epic_key, :string
    field :assignee_email, :string
    field :limit, :integer, min: 1, max: 100
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      with {:ok, opts} <- build_opts(scope, params) do
        data = Projects.list_user_stories(scope, opts) |> Enum.map(&Helpers.encode_struct/1)
        Helpers.emit_tool("list_user_stories", scope.project_id, start, :ok)
        Helpers.json_reply(frame, %{user_stories: data})
      else
        {:error, :not_found} ->
          Helpers.emit_tool("list_user_stories", scope.project_id, start, :not_found)
          Helpers.error_reply(frame, "Epic not found / Épico não encontrado")
      end
    end)
  end

  defp build_opts(scope, params) do
    opts =
      []
      |> maybe_put(:status, params[:status])
      |> maybe_put(:assignee_email, params[:assignee_email])
      |> maybe_put(:limit, params[:limit] || 50)

    case params[:epic_key] do
      nil ->
        {:ok, opts}

      epic_key ->
        case Projects.get_epic(scope, epic_key) do
          {:ok, epic} -> {:ok, Keyword.put(opts, :epic_id, epic.id)}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)
end
