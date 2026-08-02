defmodule ElxMcp.MCP.Resources.Epic do
  @moduledoc """
  Epic resource by key / Recurso de épico por chave.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "project://epics/{key}",
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
        case Projects.get_epic(scope, key) do
          {:ok, epic} ->
            {:reply, Response.json(Response.resource(), Helpers.encode_struct(epic)), frame}

          {:error, :not_found} ->
            {:reply, Response.text(Response.resource(), ~s({"error":"not_found"})), frame}
        end
    end
  end
end
