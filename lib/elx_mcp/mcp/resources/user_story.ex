defmodule ElxMcp.MCP.Resources.UserStory do
  @moduledoc """
  User story resource by key / Recurso de user story por chave.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "project://stories/{key}",
    mime_type: "application/json"

  alias Anubis.Server.Response
  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  @impl true
  def read(params, frame) do
    key = params["key"] || params[:key]

    case Helpers.scope_from_frame(frame) do
      nil ->
        {:reply, Response.text(Response.resource(), ~s({"error":"unauthorized"})), frame}

      scope ->
        case Projects.get_user_story(scope, key) do
          {:ok, story} ->
            {:reply, Response.json(Response.resource(), Helpers.encode_struct(story)), frame}

          {:error, :not_found} ->
            {:reply, Response.text(Response.resource(), ~s({"error":"not_found"})), frame}
        end
    end
  end
end
