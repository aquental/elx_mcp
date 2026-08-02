defmodule ElxMcp.MCP.Tools.GetTicket do
  @moduledoc """
  Get ticket by key / Obter ticket pela chave.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :key, :string, required: true
  end

  @impl true
  def execute(%{key: key}, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      case Projects.get_ticket(scope, key) do
        {:ok, ticket} ->
          Helpers.emit_tool("get_ticket", scope.project_id, start, :ok)
          Helpers.json_reply(frame, Helpers.encode_struct(ticket))

        {:error, :not_found} ->
          Helpers.emit_tool("get_ticket", scope.project_id, start, :not_found)
          Helpers.error_reply(frame, "Ticket not found / Ticket não encontrado: #{key}")
      end
    end)
  end
end
