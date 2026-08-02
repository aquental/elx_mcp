defmodule ElxMcpWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via `X-API-Key` header.
  """

  import Plug.Conn

  alias ElxMcp.Auth
  alias ElxMcp.Auth.RateLimit

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case RateLimit.check("mcp:" <> ip) do
      {:error, :rate_limited} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, ~s({"error":"rate_limited"}))
        |> halt()

      :ok ->
        authenticate(conn)
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "x-api-key") do
      [key] when is_binary(key) ->
        case Auth.verify_api_key(String.trim(key)) do
          {:ok, scope} ->
            # Do not put plaintext key on assigns; Anubis still receives headers from Plug —
            # never log frame.context.headers.
            conn
            |> assign(:project_id, scope.project_id)
            |> assign(:api_key_id, scope.api_key_id)
            |> assign(:api_key_email, scope.actor_email)
            |> assign(:scopes, scope.scopes)
            |> assign(:key_prefix, scope.key_prefix)
            |> assign(:current_scope, scope)
            |> delete_req_header("x-api-key")

          {:error, :unauthorized} ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
