defmodule ElxMcp.MCP.Resources.Ticket do
  @moduledoc """
  Ticket resource by key / Recurso de ticket por chave.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "project://tickets/{key}",
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
        case Projects.get_ticket(scope, key) do
          {:ok, ticket} ->
            {:reply, Response.json(Response.resource(), Helpers.encode_struct(ticket)), frame}

          {:error, :not_found} ->
            {:reply, Response.text(Response.resource(), ~s({"error":"not_found"})), frame}
        end
    end
  end
end
