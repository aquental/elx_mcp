defmodule ElxMcpWeb.Plugs.MCPAuthTest do
  use ElxMcpWeb.ConnCase, async: true

  alias ElxMcp.Auth
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "PLG", name: "Plug"})
    {:ok, _key, plaintext} = Auth.create_api_key(project.id, "p@example.com", %{})
    %{plaintext: plaintext, project: project, email: "p@example.com"}
  end

  test "401 without api key", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-email", "p@example.com")
      |> post("/mcp", %{})

    assert conn.status == 401
    assert conn.resp_body =~ "unauthorized"
  end

  test "401 without email", %{conn: conn, plaintext: plaintext} do
    conn =
      conn
      |> put_req_header("x-api-key", plaintext)
      |> post("/mcp", %{})

    assert conn.status == 401
  end

  test "401 with invalid api key", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-api-key", String.duplicate("0", 64))
      |> put_req_header("x-email", "p@example.com")
      |> post("/mcp", %{})

    assert conn.status == 401
  end

  test "401 when email does not match key", %{conn: conn, plaintext: plaintext} do
    conn =
      conn
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", "other@example.com")
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "valid key and email assign project scope without halting", %{
    conn: conn,
    plaintext: plaintext,
    project: project,
    email: email
  } do
    conn =
      conn
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    refute conn.halted
    assert conn.assigns.project_id == project.id
    assert conn.assigns.api_key_email == "p@example.com"
    assert conn.assigns.current_scope.project_id == project.id
    assert conn.assigns.scopes == ["project:read"]
    assert get_req_header(conn, "x-api-key") == []
    assert get_req_header(conn, "x-email") == []
  end

  test "OPTIONS is not auth blocked", %{conn: conn} do
    conn = %{conn | method: "OPTIONS"}
    conn = ElxMcpWeb.Plugs.MCPAuth.call(conn, [])
    refute conn.halted
  end
end
