defmodule ElxMcp.MCP.Tools.ProjectStatus do
  @moduledoc """
  Project status summary / Resumo do status do projeto.
  Counts by status plus N most recent work items.
  Contagens por status e os N itens mais recentes.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :recent_limit, :integer, min: 1, max: 50
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)
      limit = Map.get(params, :recent_limit) || 10
      data = Projects.status_summary(scope, recent_limit: limit)
      encoded = Helpers.encode_struct(data)
      Helpers.emit_tool("project_status", scope.project_id, start, :ok)
      Helpers.json_reply(frame, encoded)
    end)
  end
end
