defmodule ElxMcp.MCP.Resources.Sprint do
  @moduledoc """
  Sprint resource by id or name / Recurso de sprint por id ou nome.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "project://sprints/{id_or_name}",
    mime_type: "application/json"

  alias Anubis.Server.Response
  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  @impl true
  def read(params, frame) do
    id_or_name = params["id_or_name"] || params[:id_or_name]

    case Helpers.scope_from_frame(frame) do
      nil ->
        {:reply, Response.text(Response.resource(), ~s({"error":"unauthorized"})), frame}

      scope ->
        case Projects.get_sprint(scope, id_or_name) do
          {:ok, sprint} ->
            {:reply, Response.json(Response.resource(), Helpers.encode_struct(sprint)), frame}

          {:error, :not_found} ->
            {:reply, Response.text(Response.resource(), ~s({"error":"not_found"})), frame}
        end
    end
  end
end
