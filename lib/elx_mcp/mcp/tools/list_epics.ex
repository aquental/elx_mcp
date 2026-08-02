defmodule ElxMcp.MCP.Tools.ListEpics do
  @moduledoc """
  List epics for the authenticated project / Listar épicos do projeto autenticado.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :status, :string
    field :priority, :string
    field :limit, :integer, min: 1, max: 100
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      opts =
        []
        |> maybe_put(:status, params[:status])
        |> maybe_put(:priority, params[:priority])
        |> maybe_put(:limit, params[:limit] || 50)

      data = Projects.list_epics(scope, opts) |> Enum.map(&Helpers.encode_struct/1)
      Helpers.emit_tool("list_epics", scope.project_id, start, :ok)
      Helpers.json_reply(frame, %{epics: data})
    end)
  end

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)
end
