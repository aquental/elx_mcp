defmodule ElxMcpWeb.Plugs.CORS do
  @moduledoc """
  Lightweight CORS for the MCP endpoint. Origins from `:elx_mcp, :mcp_cors_origins`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origins = Application.get_env(:elx_mcp, :mcp_cors_origins, [])
    origin = conn |> get_req_header("origin") |> List.first()

    conn =
      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "content-type, x-api-key, x-email, mcp-session-id, accept"
      )
      |> put_resp_header("access-control-max-age", "86400")

    # Never honor "*" outside :dev (prod must set MCP_CORS_ORIGINS allowlist)
    allow_star? = origins == ["*"] and Application.get_env(:elx_mcp, :allow_cors_star, false)

    conn =
      cond do
        allow_star? ->
          put_resp_header(conn, "access-control-allow-origin", "*")

        is_binary(origin) and origin in origins and origin != "*" ->
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("vary", "Origin")

        true ->
          conn
      end

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end
end
