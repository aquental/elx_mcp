defmodule ElxMcpWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via `X-API-Key` and `X-Email` headers.

  Both are required. The API key must belong to the given email.
  Also enforces rate limits and MCP session ownership (lifecycle hijack guard).
  """

  import Plug.Conn

  alias ElxMcp.Auth
  alias ElxMcp.Auth.RateLimit
  alias ElxMcp.Auth.SessionBind

  @session_header "mcp-session-id"

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    rl = Application.get_env(:elx_mcp, :mcp_rate_limit, [])
    limit = Keyword.get(rl, :limit, 120)
    window_ms = Keyword.get(rl, :window_ms, 60_000)

    case RateLimit.check("mcp:" <> ip, limit: limit, window_ms: window_ms) do
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
        conn =
          conn
          |> assign(:project_id, scope.project_id)
          |> assign(:api_key_id, scope.api_key_id)
          |> assign(:api_key_email, scope.actor_email)
          |> assign(:scopes, scope.scopes)
          |> assign(:key_prefix, scope.key_prefix)
          |> assign(:current_scope, scope)
          |> delete_req_header("x-api-key")
          |> delete_req_header("x-email")

        enforce_session_bind(conn, scope)

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  defp enforce_session_bind(conn, scope) do
    session_id = header_value(conn, @session_header)

    case conn.method do
      "DELETE" when is_binary(session_id) and session_id != "" ->
        case SessionBind.verify_owner(session_id, scope.api_key_id, scope.project_id) do
          :ok ->
            SessionBind.unbind(session_id)
            conn

          {:error, _} ->
            forbidden(conn)
        end

      "GET" when is_binary(session_id) and session_id != "" ->
        case SessionBind.verify_owner(session_id, scope.api_key_id, scope.project_id) do
          :ok -> conn
          {:error, _} -> forbidden(conn)
        end

      "POST" when is_binary(session_id) and session_id != "" ->
        case SessionBind.bind_if_new(session_id, scope.api_key_id, scope.project_id) do
          :ok -> conn
          {:error, _} -> forbidden(conn)
        end

      _ ->
        conn
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

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, ~s({"error":"session_forbidden"}))
    |> halt()
  end
end
