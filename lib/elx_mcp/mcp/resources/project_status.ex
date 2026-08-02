defmodule ElxMcp.MCP.Resources.ProjectStatus do
  @moduledoc """
  Snapshot of authenticated project status / Snapshot do status do projeto autenticado.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri: "project://status",
    mime_type: "application/json"

  alias Anubis.Server.Response
  alias ElxMcp.MCP.Helpers
  alias ElxMcp.Projects

  @impl true
  def read(_params, frame) do
    case Helpers.scope_from_frame(frame) do
      nil ->
        {:reply, Response.text(Response.resource(), ~s({"error":"unauthorized"})), frame}

      scope ->
        data = Projects.status_summary(scope) |> Helpers.encode_struct()
        {:reply, Response.json(Response.resource(), data), frame}
    end
  end
end
