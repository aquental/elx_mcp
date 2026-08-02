defmodule ElxMcp.MCP.Tools.SearchWorkItems do
  @moduledoc """
  Search work items by key/title/description / Buscar itens por chave/título/descrição.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :q, :string, required: true
    field :limit, :integer, min: 1, max: 50
  end

  @impl true
  def execute(%{q: q} = params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)
      limit = Map.get(params, :limit) || 25
      data = Projects.search_work_items(scope, q, limit: limit)
      Helpers.emit_tool("search_work_items", scope.project_id, start, :ok)
      Helpers.json_reply(frame, %{results: data})
    end)
  end
end
