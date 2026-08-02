defmodule ElxMcp.MCP.Tools.ListChangelog do
  @moduledoc """
  List changelog for an entity / Histórico de mudanças de uma entidade.
  """

  use Anubis.Server.Component, type: :tool

  alias ElxMcp.Collaboration
  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  schema do
    field :entity_type, :string, required: true
    field :entity_key, :string, required: true
    field :limit, :integer, min: 1, max: 100
  end

  @impl true
  def execute(%{entity_type: type, entity_key: key} = params, frame) do
    Helpers.with_scope(frame, fn scope ->
      start = System.monotonic_time(:millisecond)
      limit = Map.get(params, :limit) || 50

      case resolve_entity(scope, type, key) do
        {:ok, entity_id} ->
          entries =
            Collaboration.list_changelog(scope, type, entity_id, limit: limit)
            |> Enum.map(&Helpers.encode_struct/1)

          Helpers.emit_tool("list_changelog", scope.project_id, start, :ok)
          Helpers.json_reply(frame, %{changelog: entries})

        {:error, _} ->
          Helpers.emit_tool("list_changelog", scope.project_id, start, :not_found)
          Helpers.error_reply(frame, "Entity not found / Entidade não encontrada")
      end
    end)
  end

  defp resolve_entity(scope, "epic", key) do
    case Projects.get_epic(scope, key) do
      {:ok, e} -> {:ok, e.id}
      err -> err
    end
  end

  defp resolve_entity(scope, "user_story", key) do
    case Projects.get_user_story(scope, key) do
      {:ok, s} -> {:ok, s.id}
      err -> err
    end
  end

  defp resolve_entity(scope, "ticket", key) do
    case Projects.get_ticket(scope, key) do
      {:ok, t} -> {:ok, t.id}
      err -> err
    end
  end

  defp resolve_entity(_, _, _), do: {:error, :invalid_type}
end
