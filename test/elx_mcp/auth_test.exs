defmodule ElxMcp.AuthTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Auth
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "AUTH", name: "Auth Proj"})
    %{project: project}
  end

  test "create and verify api key", %{project: project} do
    assert {:ok, key, plaintext} =
             Auth.create_api_key(project.id, "User@Example.com", %{name: "test"})

    assert key.email == "user@example.com"
    assert byte_size(key.key_hash) == 32
    assert String.length(plaintext) == 64

    assert {:ok, scope} = Auth.verify_api_key(plaintext)
    assert scope.project_id == project.id
    assert scope.actor_email == "user@example.com"
    assert "project:read" in scope.scopes
  end

  test "multiple keys per email", %{project: project} do
    assert {:ok, _, _} = Auth.create_api_key(project.id, "a@b.com", %{})
    assert {:ok, _, _} = Auth.create_api_key(project.id, "a@b.com", %{})
    assert length(Auth.list_api_keys(project.id)) == 2
  end

  test "revoked key fails verification", %{project: project} do
    {:ok, key, plaintext} = Auth.create_api_key(project.id, "a@b.com", %{})
    assert {:ok, _} = Auth.revoke_api_key(key)
    assert {:error, :unauthorized} = Auth.verify_api_key(plaintext)
  end

  test "invalid key fails", %{project: _project} do
    assert {:error, :unauthorized} = Auth.verify_api_key("not-a-key")
    assert {:error, :unauthorized} = Auth.verify_api_key(String.duplicate("a", 64))
    assert {:error, :unauthorized} = Auth.verify_api_key(nil)
  end

  test "key without project:read is unauthorized", %{project: project} do
    # Force a key that has only write (bypass create allow if needed via insert)
    raw = :crypto.strong_rand_bytes(32)
    plaintext = Base.encode16(raw, case: :lower)
    hash = :crypto.hash(:sha256, raw)

    {:ok, _} =
      %ElxMcp.Auth.ApiKey{}
      |> Ecto.Changeset.change(%{
        project_id: project.id,
        email: "w@example.com",
        key_hash: hash,
        key_prefix: "deadbeef",
        scopes: ["project:write"]
      })
      |> ElxMcp.Repo.insert()

    assert {:error, :unauthorized} = Auth.verify_api_key(plaintext)
  end

  test "rejects invalid scopes at create", %{project: project} do
    assert {:error, :invalid_scopes} =
             Auth.create_api_key(project.id, "a@b.com", %{scopes: ["admin"]})
  end
end
