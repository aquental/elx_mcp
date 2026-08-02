defmodule ElxMcpWeb.Plugs.MCPAuthSessionTest do
  @moduledoc """
  Session-bind lifecycle tests. `async: false` because SessionBind ETS is global.
  """
  use ElxMcpWeb.ConnCase, async: false

  alias ElxMcp.Auth
  alias ElxMcp.Auth.SessionBind
  alias ElxMcp.Tenancy

  setup do
    SessionBind.setup!()
    SessionBind.reset!()

    {:ok, project} = Tenancy.create_project(%{key: "SES", name: "Session"})
    {:ok, _key, plaintext} = Auth.create_api_key(project.id, "s@example.com", %{})

    on_exit(fn -> SessionBind.reset!() end)

    %{plaintext: plaintext, project: project, email: "s@example.com"}
  end

  test "POST binds session; same principal re-POST ok", %{
    conn: conn,
    plaintext: plaintext,
    email: email
  } do
    sid = "sess-owner-#{System.unique_integer()}"

    conn1 =
      %{conn | method: "POST"}
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    refute conn1.halted

    conn2 =
      build_conn()
      |> Map.put(:method, "POST")
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    refute conn2.halted
  end

  test "POST rejects foreign principal", %{
    conn: conn,
    plaintext: plaintext,
    email: email,
    project: project
  } do
    sid = "sess-post-#{System.unique_integer()}"
    :ok = SessionBind.bind_if_new(sid, Ecto.UUID.generate(), project.id)

    conn =
      %{conn | method: "POST"}
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "session_forbidden"
  end

  test "DELETE rejects foreign principal", %{
    conn: conn,
    plaintext: plaintext,
    email: email,
    project: project
  } do
    sid = "sess-del-#{System.unique_integer()}"
    :ok = SessionBind.bind_if_new(sid, Ecto.UUID.generate(), project.id)

    conn =
      %{conn | method: "DELETE"}
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "session_forbidden"
  end

  test "GET rejects foreign principal", %{
    conn: conn,
    plaintext: plaintext,
    email: email,
    project: project
  } do
    sid = "sess-get-#{System.unique_integer()}"
    :ok = SessionBind.bind_if_new(sid, Ecto.UUID.generate(), project.id)

    conn =
      %{conn | method: "GET"}
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    assert conn.halted
    assert conn.status == 403
  end

  test "owner DELETE unbinds session", %{
    conn: conn,
    plaintext: plaintext,
    email: email,
    project: project
  } do
    {:ok, scope} = Auth.verify_api_key(plaintext, email)
    sid = "sess-unbind-#{System.unique_integer()}"
    :ok = SessionBind.bind_if_new(sid, scope.api_key_id, project.id)

    conn =
      %{conn | method: "DELETE"}
      |> put_req_header("x-api-key", plaintext)
      |> put_req_header("x-email", email)
      |> put_req_header("mcp-session-id", sid)
      |> ElxMcpWeb.Plugs.MCPAuth.call([])

    refute conn.halted
    # Unbound: another principal can bind
    other = Ecto.UUID.generate()
    assert :ok = SessionBind.bind_if_new(sid, other, project.id)
  end
end
