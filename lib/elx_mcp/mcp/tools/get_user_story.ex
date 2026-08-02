defmodule ElxMcp.MCP.Tools.GetUserStory do
  @moduledoc """
  Get user story by key / Obter user story pela chave.
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

      case Projects.get_user_story(scope, key) do
        {:ok, story} ->
          Helpers.emit_tool("get_user_story", scope, start, :ok, params)
          Helpers.json_reply(frame, Helpers.encode_struct(story))

        {:error, :not_found} ->
          Helpers.emit_tool("get_user_story", scope, start, :not_found, params)
          Helpers.error_reply(frame, "User story not found / Story não encontrada: #{key}")
      end
    end)
  end
end
