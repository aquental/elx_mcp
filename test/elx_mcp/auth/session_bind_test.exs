defmodule ElxMcp.Auth.SessionBindTest do
  use ExUnit.Case, async: false

  alias ElxMcp.Auth.SessionBind

  setup do
    SessionBind.setup!()
    SessionBind.reset!()
    :ok
  end

  test "bind_if_new allows same owner and rejects other" do
    sid = "sess-#{System.unique_integer()}"
    key_a = Ecto.UUID.generate()
    key_b = Ecto.UUID.generate()
    proj = Ecto.UUID.generate()

    assert :ok = SessionBind.bind_if_new(sid, key_a, proj)
    assert :ok = SessionBind.bind_if_new(sid, key_a, proj)
    assert {:error, :forbidden} = SessionBind.bind_if_new(sid, key_b, proj)
    assert {:error, :forbidden} = SessionBind.verify_owner(sid, key_b, proj)
    assert :ok = SessionBind.verify_owner(sid, key_a, proj)
  end

  test "unbound session verify_owner is not_found (fail-closed)" do
    assert {:error, :not_found} =
             SessionBind.verify_owner("unknown", Ecto.UUID.generate(), Ecto.UUID.generate())
  end

  test "unbind allows rebind by another principal" do
    sid = "sess-re-#{System.unique_integer()}"
    key_a = Ecto.UUID.generate()
    key_b = Ecto.UUID.generate()
    proj = Ecto.UUID.generate()

    assert :ok = SessionBind.bind_if_new(sid, key_a, proj)
    SessionBind.unbind(sid)
    assert :ok = SessionBind.bind_if_new(sid, key_b, proj)
    assert :ok = SessionBind.verify_owner(sid, key_b, proj)
  end
end
