defmodule ElxMcp.MCP.Tools.ListBoards do
  @moduledoc """
  List boards / Listar boards do projeto.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :limit, :integer, min: 1, max: 200
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)
      limit = Map.get(params, :limit) || 100

      data =
        Projects.list_boards(scope, limit: limit) |> Enum.map(&Helpers.encode_struct/1)

      Helpers.emit_tool("list_boards", scope.project_id, start, :ok)
      Helpers.json_reply(frame, %{boards: data})
    end)
  end
end
