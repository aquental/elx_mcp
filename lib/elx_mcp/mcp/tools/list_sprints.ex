defmodule ElxMcp.MCP.Tools.ListSprints do
  @moduledoc """
  List sprints / Listar sprints do projeto.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :status, :string
    field :limit, :integer, min: 1, max: 200
  end

  @impl true
  def execute(params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      opts =
        []
        |> then(fn o ->
          if params[:status], do: Keyword.put(o, :status, params[:status]), else: o
        end)
        |> Keyword.put(:limit, params[:limit] || 100)

      data = Projects.list_sprints(scope, opts) |> Enum.map(&Helpers.encode_struct/1)
      Helpers.emit_tool("list_sprints", scope, start, :ok, params)
      Helpers.json_reply(frame, %{sprints: data})
    end)
  end
end
