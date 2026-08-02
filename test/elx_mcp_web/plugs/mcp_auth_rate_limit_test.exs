defmodule ElxMcpWeb.Plugs.MCPAuthRateLimitTest do
  use ElxMcpWeb.ConnCase, async: false

  alias ElxMcp.Auth.RateLimit

  setup do
    previous = Application.get_env(:elx_mcp, :mcp_rate_limit)

    Application.put_env(:elx_mcp, :mcp_rate_limit, limit: 5, window_ms: 60_000)
    RateLimit.setup!()
    RateLimit.reset!()

    on_exit(fn ->
      if previous do
        Application.put_env(:elx_mcp, :mcp_rate_limit, previous)
      else
        Application.delete_env(:elx_mcp, :mcp_rate_limit)
      end

      RateLimit.reset!()
    end)

    :ok
  end

  test "returns 429 with retry-after when over limit", %{conn: conn} do
    # Use a unique remote_ip so we don't collide with other suite traffic
    conn = %{conn | remote_ip: {203, 0, 113, 50}}

    # 5 allowed, 6th rate limited (unauthenticated still counts)
    results =
      for _ <- 1..6 do
        c =
          conn
          |> recycle()
          |> Map.put(:remote_ip, {203, 0, 113, 50})
          |> put_req_header("x-email", "r@example.com")
          |> ElxMcpWeb.Plugs.MCPAuth.call([])

        c.status
      end

    assert Enum.count(results, &(&1 == 401)) == 5
    assert List.last(results) == 429

    limited =
      conn
      |> recycle()
      |> Map.put(:remote_ip, {203, 0, 113, 50})
      |> put_req_header("x-email", "r@example.com")
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") == ["60"]
    assert limited.resp_body =~ "rate_limited"
  end
end
