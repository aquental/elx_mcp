defmodule ElxMcp.TenancyTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Tenancy

  test "creates project and generates sequential issue keys" do
    {:ok, project} = Tenancy.create_project(%{key: "acme", name: "Acme"})
    assert project.key == "ACME"

    assert {:ok, "ACME-1"} = Tenancy.next_issue_key(project.id)
    assert {:ok, "ACME-2"} = Tenancy.next_issue_key(project.id)

    reloaded = Tenancy.get_project!(project.id)
    assert reloaded.issue_counter == 2
  end

  test "rejects invalid project key" do
    assert {:error, changeset} = Tenancy.create_project(%{key: "x", name: "X"})
    assert %{key: _} = errors_on(changeset)
  end
end
