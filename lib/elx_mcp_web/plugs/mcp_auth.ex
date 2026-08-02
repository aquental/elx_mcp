defmodule ElxMcpWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via `X-API-Key` and `X-Email` headers.

  Both are required. The API key must belong to the given email.
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
    api_key = header_value(conn, "x-api-key")
    email = header_value(conn, "x-email")

    case Auth.verify_api_key(api_key, email) do
      {:ok, scope} ->
        # Do not put plaintext key on assigns; never log frame.context.headers.
        conn
        |> assign(:project_id, scope.project_id)
        |> assign(:api_key_id, scope.api_key_id)
        |> assign(:api_key_email, scope.actor_email)
        |> assign(:scopes, scope.scopes)
        |> assign(:key_prefix, scope.key_prefix)
        |> assign(:current_scope, scope)
        |> delete_req_header("x-api-key")
        |> delete_req_header("x-email")

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  defp header_value(conn, name) do
    case get_req_header(conn, name) do
      [value] when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
