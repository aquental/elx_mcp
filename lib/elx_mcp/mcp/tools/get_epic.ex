defmodule ElxMcp.MCP.Tools.GetEpic do
  @moduledoc """
  Get epic by key / Obter épico pela chave (ex.: PROJ-1).
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :key, :string, required: true
  end

  @impl true
  def execute(%{key: key} = params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      case Projects.get_epic(scope, key) do
        {:ok, epic} ->
          Helpers.emit_tool("get_epic", scope, start, :ok, params)
          Helpers.json_reply(frame, Helpers.encode_struct(epic))

        {:error, :not_found} ->
          Helpers.emit_tool("get_epic", scope, start, :not_found, params)
          Helpers.error_reply(frame, "Epic not found / Épico não encontrado: #{key}")
      end
    end)
  end
end
