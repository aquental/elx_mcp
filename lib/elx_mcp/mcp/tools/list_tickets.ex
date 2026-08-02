defmodule ElxMcp.MCP.Tools.ListTickets do
  @moduledoc """
  List tickets / Listar tickets do projeto.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :status, :string
    field :type, :string
    field :story_key, :string
    field :assignee_email, :string
    field :limit, :integer, min: 1, max: 100
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      with {:ok, opts} <- build_opts(scope, params) do
        data = Projects.list_tickets(scope, opts) |> Enum.map(&Helpers.encode_struct/1)
        Helpers.emit_tool("list_tickets", scope, start, :ok, params)
        Helpers.json_reply(frame, %{tickets: data})
      else
        {:error, :not_found} ->
          Helpers.emit_tool("list_tickets", scope, start, :not_found, params)
          Helpers.error_reply(frame, "User story not found / Story não encontrada")
      end
    end)
  end

  defp build_opts(scope, params) do
    opts =
      []
      |> maybe_put(:status, params[:status])
      |> maybe_put(:type, params[:type])
      |> maybe_put(:assignee_email, params[:assignee_email])
      |> maybe_put(:limit, params[:limit] || 50)

    case params[:story_key] do
      nil ->
        {:ok, opts}

      story_key ->
        case Projects.get_user_story_id(scope, story_key) do
          {:ok, id} -> {:ok, Keyword.put(opts, :user_story_id, id)}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)
end
