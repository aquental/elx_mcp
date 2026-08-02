defmodule ElxMcp.RlsTest do
  use ElxMcp.DataCase, async: false

  alias ElxMcp.Auth
  alias ElxMcp.Auth.Scope
  alias ElxMcp.Projects
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy

  setup do
    {:ok, p1} = Tenancy.create_project(%{key: "RLS1", name: "Tenant One"})
    {:ok, p2} = Tenancy.create_project(%{key: "RLS2", name: "Tenant Two"})

    s1 = write_scope(p1.id, "a@example.com")
    s2 = write_scope(p2.id, "b@example.com")

    {:ok, _} = Projects.create_board(s1, %{name: "Board-A"})
    {:ok, _} = Projects.create_board(s2, %{name: "Board-B"})

    %{p1: p1, p2: p2, s1: s1, s2: s2}
  end

  defp secdef_bypassrls_role? do
    case Ecto.Adapters.SQL.query(
           Repo,
           """
           SELECT EXISTS (
             SELECT 1 FROM pg_roles
             WHERE rolname = 'elx_mcp_secdef' AND rolbypassrls
           )
           """,
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp policies_uuid_only_no_bypass? do
    case Ecto.Adapters.SQL.query(
           Repo,
           """
           SELECT NOT EXISTS (
             SELECT 1
             FROM pg_policies
             WHERE schemaname = 'public'
               AND qual ILIKE '%bypass_rls%'
           )
           """,
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp allow_missing_secdef? do
    System.get_env("ELX_MCP_ALLOW_MISSING_SECDEF") in ["1", "true", "TRUE"]
  end

  test "with_tenant isolates boards per project", %{s1: s1, s2: s2} do
    assert Enum.map(Projects.list_boards(s1), & &1.name) == ["Board-A"]
    assert Enum.map(Projects.list_boards(s2), & &1.name) == ["Board-B"]
  end

  test "raw SELECT without tenant GUC sees no tenant rows after with_tenant ends", %{s1: s1} do
    # Ensure a tenant transaction ran and completed (LOCAL GUC should not leak)
    assert [_ | _] = Projects.list_boards(s1)

    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
  end

  test "wrong tenant GUC cannot see other project's boards", %{p1: p1, p2: p2} do
    # Force GUC of p1 then query boards (should only see p1)
    Repo.with_tenant(p1.id, fn ->
      assert {:ok, %{rows: [[1]]}} =
               Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
    end)

    Repo.with_tenant(p2.id, fn ->
      assert {:ok, %{rows: [[1]]}} =
               Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
    end)

    # After transactions end, no residual visibility
    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
  end

  test "WITH CHECK rejects insert for mismatched project_id", %{s1: s1, p2: p2} do
    # Attempt insert of board for p2 while GUC is s1
    assert_raise Postgrex.Error, ~r/row-level security|policy|violates/i, fn ->
      {:ok, p2_bin} = Ecto.UUID.dump(p2.id)

      Repo.with_tenant(s1.project_id, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO boards (id, project_id, name, type, metadata, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1::uuid, 'evil', 'scrum', '{}', now(), now())
          """,
          [p2_bin]
        )
      end)
    end
  end

  test "verify_api_key works on a cold path (SECURITY DEFINER, no prior tenant GUC)", %{
    p1: p1
  } do
    # Clear any residual session state by running a no-tenant query first
    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])

    {:ok, _key, plain} = Auth.create_api_key(p1.id, "cold@example.com", %{name: "cold"})

    # After create_api_key transaction ends, GUC must not remain
    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])

    assert {:ok, scope} = Auth.verify_api_key(plain, "cold@example.com")
    assert scope.project_id == p1.id
    assert scope.actor_email == "cold@example.com"
  end

  test "verify_api_key fails for wrong email", %{p1: p1} do
    {:ok, _key, plain} = Auth.create_api_key(p1.id, "owner@example.com", %{name: "k"})
    assert {:error, :unauthorized} = Auth.verify_api_key(plain, "other@example.com")
  end

  test "get_project_by_key and list_projects work without tenant GUC", %{p1: p1} do
    assert %{id: id} = Tenancy.get_project_by_key("RLS1")
    assert id == p1.id

    keys = Tenancy.list_projects() |> Enum.map(& &1.key)
    assert "RLS1" in keys
    assert "RLS2" in keys
  end

  test "nested with_tenant same project keeps isolation", %{p1: p1, s1: s1} do
    Repo.with_tenant(p1.id, fn ->
      assert length(Projects.list_boards(s1)) == 1

      Repo.with_tenant(p1.id, fn ->
        assert length(Projects.list_boards(s1)) == 1
      end)

      assert length(Projects.list_boards(s1)) == 1
    end)

    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
  end

  test "nested with_tenant different projects switches and restores GUC", %{
    p1: p1,
    p2: p2,
    s1: s1,
    s2: s2
  } do
    Repo.with_tenant(p1.id, fn ->
      assert Enum.map(Projects.list_boards(s1), & &1.name) == ["Board-A"]

      Repo.with_tenant(p2.id, fn ->
        assert Enum.map(Projects.list_boards(s2), & &1.name) == ["Board-B"]
      end)

      assert Enum.map(Projects.list_boards(s1), & &1.name) == ["Board-A"]
    end)

    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
  end

  test "SECDEF inside open TX does not leak bypass to subsequent queries", %{p1: p1} do
    # UUID-only policies + elx_mcp_secdef BYPASSRLS required for isolation assert.
    # Local without bootstrap: ELX_MCP_ALLOW_MISSING_SECDEF=1 (default off / CI).
    cond do
      secdef_bypassrls_role?() ->
        Repo.transaction(fn ->
          assert %{id: id} = Tenancy.get_project_by_key("RLS1")
          assert id == p1.id
          _ = Tenancy.list_projects()

          assert {:ok, %{rows: [[0]]}} =
                   Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
        end)

      policies_uuid_only_no_bypass?() and not allow_missing_secdef?() ->
        flunk("""
        Policies are UUID-only (no app.bypass_rls) but role elx_mcp_secdef (BYPASSRLS) is missing.
        Bootstrap: priv/repo/manual/create_elx_mcp_secdef_role.sql then mix ecto.migrate.
        Local opt-out only: ELX_MCP_ALLOW_MISSING_SECDEF=1
        """)

      true ->
        # Pre-UUID-only cluster or explicit opt-out: skip isolation assert
        :ok
    end
  end

  test "missing project after key lookup is unauthorized" do
    # DDL needs exclusive locks — keep in async:false suite (not AuthTest).
    {:ok, project} = Tenancy.create_project(%{key: "ORPH", name: "Orphan Proj"})
    {:ok, key, plaintext} = Auth.create_api_key(project.id, "orphan@example.com", %{name: "orph"})

    orphan_id = Ecto.UUID.generate()
    {:ok, orphan_bin} = Ecto.UUID.dump(orphan_id)
    {:ok, key_bin} = Ecto.UUID.dump(key.id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE api_keys DROP CONSTRAINT api_keys_project_id_fkey"
    )

    Ecto.Adapters.SQL.query!(Repo, "ALTER TABLE api_keys DISABLE ROW LEVEL SECURITY")

    %{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE api_keys SET project_id = $1 WHERE id = $2",
        [orphan_bin, key_bin]
      )

    assert {:error, :unauthorized} = Auth.verify_api_key(plaintext, "orphan@example.com")
  end

  test "constraint error under with_tenant returns error without aborting clear path" do
    # Duplicate project key via create_project (own with_tenant) → {:error, changeset}
    # Must not raise on post-fun clear.
    assert {:error, %Ecto.Changeset{}} = Tenancy.create_project(%{key: "RLS1", name: "Dup"})

    # Process / GUC hygiene after error — no residual board visibility
    assert {:ok, %{rows: [[0]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT count(*)::int FROM boards", [])
  end

  test "WITH CHECK rejects mismatched comment insert (W14 sample)", %{s1: s1, p2: p2} do
    assert_raise Postgrex.Error, ~r/row-level security|policy|violates/i, fn ->
      {:ok, p2_bin} = Ecto.UUID.dump(p2.id)

      Repo.with_tenant(s1.project_id, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO comments (
            id, project_id, commentable_type, commentable_id,
            author_email, body, inserted_at, updated_at
          )
          VALUES (
            gen_random_uuid(), $1::uuid, 'ticket', gen_random_uuid(),
            'evil@x.com', 'nope', now(), now()
          )
          """,
          [p2_bin]
        )
      end)
    end
  end

  defp write_scope(project_id, email) do
    %Scope{
      project_id: project_id,
      actor_email: email,
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read", "project:write"]
    }
  end
end
