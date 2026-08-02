defmodule ElxMcp.MCP.Tools.ListComments do
  @moduledoc """
  List comments on an entity / Listar comentários de uma entidade.
  entity_type: epic | user_story | ticket
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.Collaboration
  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :entity_type, :string, required: true
    field :entity_key, :string, required: true
  end

  @impl true
  def execute(%{entity_type: type, entity_key: key} = params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)

      case resolve_entity(scope, type, key) do
        {:ok, entity_id} ->
          comments =
            Collaboration.list_comments(scope, type, entity_id)
            |> Enum.map(&Helpers.encode_struct/1)

          Helpers.emit_tool("list_comments", scope, start, :ok, params)
          Helpers.json_reply(frame, %{comments: comments})

        {:error, _} ->
          Helpers.emit_tool("list_comments", scope, start, :not_found, params)
          Helpers.error_reply(frame, "Entity not found / Entidade não encontrada")
      end
    end)
  end

  defp resolve_entity(scope, "epic", key), do: Projects.get_epic_id(scope, key)
  defp resolve_entity(scope, "user_story", key), do: Projects.get_user_story_id(scope, key)
  defp resolve_entity(scope, "ticket", key), do: Projects.get_ticket_id(scope, key)
  defp resolve_entity(_, _, _), do: {:error, :invalid_type}
end
