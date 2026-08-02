defmodule ElxMcp.ProjectsTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Auth.Scope
  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "PRJ", name: "Project"})

    read_scope = %Scope{
      project_id: project.id,
      actor_email: "a@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read"]
    }

    write_scope = %{read_scope | scopes: ["project:read", "project:write"]}

    %{project: project, scope: read_scope, write_scope: write_scope}
  end

  test "story without epic is allowed", %{write_scope: write_scope, scope: scope} do
    assert {:ok, story} =
             Projects.create_user_story(write_scope, %{title: "Orphan story", status: "to_do"})

    assert is_nil(story.epic_id)
    assert story.key == "PRJ-1"
    assert [_] = Projects.list_user_stories(scope)
  end

  test "ticket without story is rejected", %{write_scope: write_scope} do
    assert {:error, changeset} =
             Projects.create_ticket(write_scope, %{title: "No story", type: "task"})

    assert %{user_story_id: _} = errors_on(changeset)
  end

  test "create requires project:write", %{scope: scope} do
    assert {:error, :forbidden} = Projects.create_epic(scope, %{title: "Nope"})
  end

  test "subtask requires parent_ticket_id", %{write_scope: write_scope} do
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S"})

    assert {:error, changeset} =
             Projects.create_ticket(write_scope, %{
               title: "Sub",
               type: "subtask",
               user_story_id: story.id
             })

    assert %{parent_ticket_id: _} = errors_on(changeset)
  end

  test "creates ticket under story and lists by tenant", %{
    write_scope: write_scope,
    scope: scope
  } do
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S"})
    {:ok, ticket} = Projects.create_ticket(write_scope, %{title: "T", user_story_id: story.id})

    assert ticket.key =~ ~r/^PRJ-\d+$/
    assert {:ok, found} = Projects.get_ticket(scope, ticket.key)
    assert found.id == ticket.id
  end

  test "cross-tenant isolation", %{write_scope: write_scope, scope: scope} do
    {:ok, other} = Tenancy.create_project(%{key: "OTH", name: "Other"})
    other_scope = %{scope | project_id: other.id}

    {:ok, story} = Projects.create_user_story(write_scope, %{title: "Private"})

    {:ok, ticket} =
      Projects.create_ticket(write_scope, %{title: "Secret", user_story_id: story.id})

    assert [] = Projects.list_user_stories(other_scope)
    assert {:error, :not_found} = Projects.get_ticket(other_scope, ticket.key)
  end

  test "status_summary includes counts and recent", %{write_scope: write_scope, scope: scope} do
    {:ok, story} =
      Projects.create_user_story(write_scope, %{title: "S", status: "in_progress"})

    {:ok, _} = Projects.create_ticket(write_scope, %{title: "T", user_story_id: story.id})

    summary = Projects.status_summary(scope, recent_limit: 5)
    assert summary.stories_by_status["in_progress"] == 1
    assert is_list(summary.recent)
    assert length(summary.recent) >= 1
  end

  test "boards, sprints, epics, search", %{write_scope: write_scope, scope: scope} do
    {:ok, board} = Projects.create_board(write_scope, %{name: "Board A"})
    {:ok, sprint} = Projects.create_sprint(write_scope, %{name: "S1", board_id: board.id})
    {:ok, epic} = Projects.create_epic(write_scope, %{title: "Epic Searchable"})

    assert length(Projects.list_boards(scope)) >= 1
    assert length(Projects.list_sprints(scope)) >= 1
    assert {:ok, _} = Projects.get_sprint(scope, sprint.name)
    assert {:ok, _} = Projects.get_epic(scope, epic.key)

    results = Projects.search_work_items(scope, "Searchable")
    assert Enum.any?(results, &(&1.key == epic.key))

    # exact key fast path
    exact = Projects.search_work_items(scope, epic.key)
    assert Enum.any?(exact, &(&1.key == epic.key))
  end

  test "search does not match description by default", %{write_scope: write_scope, scope: scope} do
    {:ok, epic} =
      Projects.create_epic(write_scope, %{
        title: "Visible Title",
        description: "UniqueDescTokenXYZ"
      })

    assert [] = Projects.search_work_items(scope, "UniqueDescTokenXYZ")

    with_desc =
      Projects.search_work_items(scope, "UniqueDescTokenXYZ", include_description: true)

    assert Enum.any?(with_desc, &(&1.key == epic.key))
  end

  test "search rank order exact key before prefix before title", %{
    write_scope: write_scope,
    scope: scope
  } do
    # Query "PRJ-1":
    # - exact: key PRJ-1 (rank 0)
    # - prefix: key PRJ-10 (rank 1, ILIKE 'PRJ-1%')
    # - title: key PRJ-2 with "PRJ-1" only in title (rank 2; key does not match prefix)
    {:ok, exact} = Projects.create_epic(write_scope, %{title: "Exact holder"})
    assert exact.key == "PRJ-1"

    {:ok, title_hit} =
      Projects.create_epic(write_scope, %{title: "Mentions PRJ-1 in title only"})

    assert title_hit.key == "PRJ-2"

    epics =
      for i <- 3..10 do
        {:ok, e} = Projects.create_epic(write_scope, %{title: "Epic #{i}"})
        e
      end

    prefix_hit = Enum.find(epics, &(&1.key == "PRJ-10"))
    assert prefix_hit

    results = Projects.search_work_items(scope, "PRJ-1", limit: 50)
    keys = Enum.map(results, & &1.key)

    exact_idx = Enum.find_index(keys, &(&1 == exact.key))
    prefix_idx = Enum.find_index(keys, &(&1 == prefix_hit.key))
    title_idx = Enum.find_index(keys, &(&1 == title_hit.key))

    assert exact_idx == 0
    assert prefix_idx != nil
    assert title_idx != nil
    assert exact_idx < prefix_idx
    assert prefix_idx < title_idx
  end

  test "search treats % and _ as literals not wildcards", %{
    write_scope: write_scope,
    scope: scope
  } do
    {:ok, plain} = Projects.create_epic(write_scope, %{title: "plain title no specials"})

    # Unescaped %/_ would match every title; with ESCAPE they only match literal chars
    assert [] = Projects.search_work_items(scope, "%")
    assert [] = Projects.search_work_items(scope, "_")

    assert Enum.any?(
             Projects.search_work_items(scope, "plain"),
             &(&1.key == plain.key)
           )

    {:ok, special} =
      Projects.create_epic(write_scope, %{title: "100%_complete rare token"})

    hits = Projects.search_work_items(scope, "100%_complete")
    assert Enum.any?(hits, &(&1.key == special.key))
  end

  test "search empty or whitespace query returns empty; limit capped", %{
    write_scope: write_scope,
    scope: scope
  } do
    for i <- 1..5 do
      {:ok, _} = Projects.create_epic(write_scope, %{title: "Cap #{i}"})
    end

    assert [] = Projects.search_work_items(scope, "")
    assert [] = Projects.search_work_items(scope, "   ")

    # limit above hard cap still returns at most 50 (smoke with small set)
    results = Projects.search_work_items(scope, "Cap", limit: 100)
    assert length(results) <= 50
  end

  test "ensure_entity_in_project validation cases", %{
    write_scope: write_scope,
    project: project
  } do
    {:ok, epic} = Projects.create_epic(write_scope, %{title: "E"})
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S", epic_id: epic.id})
    {:ok, ticket} = Projects.create_ticket(write_scope, %{title: "T", user_story_id: story.id})

    ElxMcp.Repo.with_tenant(project.id, fn ->
      assert :ok = Projects.ensure_entity_in_project(project.id, "epic", epic.id)
      assert :ok = Projects.ensure_entity_in_project(project.id, "user_story", story.id)
      assert :ok = Projects.ensure_entity_in_project(project.id, "ticket", ticket.id)

      assert {:error, :invalid_association} =
               Projects.ensure_entity_in_project(project.id, nil, epic.id)

      assert {:error, :invalid_association} =
               Projects.ensure_entity_in_project(project.id, "epic", nil)

      assert {:error, :invalid_association} =
               Projects.ensure_entity_in_project(project.id, "unknown", epic.id)

      assert {:error, :invalid_association} =
               Projects.ensure_entity_in_project(project.id, "epic", Ecto.UUID.generate())
    end)

    {:ok, other} = Tenancy.create_project(%{key: "ENS", name: "Ens"})

    ElxMcp.Repo.with_tenant(other.id, fn ->
      assert {:error, :invalid_association} =
               Projects.ensure_entity_in_project(other.id, "epic", epic.id)
    end)
  end

  test "rejects cross-tenant story association", %{write_scope: write_scope} do
    {:ok, other} = Tenancy.create_project(%{key: "ZZZ", name: "Z"})

    other_write = %Scope{
      project_id: other.id,
      actor_email: "a@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read", "project:write"]
    }

    {:ok, foreign_story} = Projects.create_user_story(other_write, %{title: "Foreign"})

    assert {:error, :invalid_association} =
             Projects.create_ticket(write_scope, %{
               title: "Bad",
               user_story_id: foreign_story.id
             })
  end

  test "detects parent ticket cycle", %{write_scope: write_scope} do
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S"})
    {:ok, a} = Projects.create_ticket(write_scope, %{title: "A", user_story_id: story.id})

    {:ok, b} =
      Projects.create_ticket(write_scope, %{
        title: "B",
        type: "subtask",
        user_story_id: story.id,
        parent_ticket_id: a.id
      })

    # A → parent B would cycle (B already parents under A)
    assert {:error, :cycle_detected} =
             Projects.update_ticket_parent(write_scope, a.id, b.id)
  end

  test "list_epics applies default limit", %{write_scope: write_scope, scope: scope} do
    for i <- 1..3 do
      assert {:ok, _} = Projects.create_epic(write_scope, %{title: "E#{i}"})
    end

    assert length(Projects.list_epics(scope)) <= 50
  end

  test "get_ticket_id resolves without preload", %{write_scope: write_scope, scope: scope} do
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S"})
    {:ok, ticket} = Projects.create_ticket(write_scope, %{title: "T", user_story_id: story.id})

    assert {:ok, id} = Projects.get_ticket_id(scope, ticket.key)
    assert id == ticket.id
  end

  test "increment_time_spent returns not_found for missing ticket", %{project: project} do
    missing = Ecto.UUID.generate()

    assert {:error, :not_found} =
             Projects.increment_time_spent(project.id, missing, 60)
  end
end
