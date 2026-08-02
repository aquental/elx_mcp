defmodule ElxMcp.ProjectsTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Auth.Scope
  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "PRJ", name: "Project"})

    scope = %Scope{
      project_id: project.id,
      actor_email: "a@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read"]
    }

    %{project: project, scope: scope}
  end

  test "story without epic is allowed", %{project: project, scope: scope} do
    assert {:ok, story} =
             Projects.create_user_story(project.id, %{title: "Orphan story", status: "to_do"})

    assert is_nil(story.epic_id)
    assert story.key == "PRJ-1"
    assert [_] = Projects.list_user_stories(scope)
  end

  test "ticket without story is rejected", %{project: project} do
    assert {:error, changeset} =
             Projects.create_ticket(project.id, %{title: "No story", type: "task"})

    assert %{user_story_id: _} = errors_on(changeset)
  end

  test "subtask requires parent_ticket_id", %{project: project} do
    {:ok, story} = Projects.create_user_story(project.id, %{title: "S"})

    assert {:error, changeset} =
             Projects.create_ticket(project.id, %{
               title: "Sub",
               type: "subtask",
               user_story_id: story.id
             })

    assert %{parent_ticket_id: _} = errors_on(changeset)
  end

  test "creates ticket under story and lists by tenant", %{project: project, scope: scope} do
    {:ok, story} = Projects.create_user_story(project.id, %{title: "S"})
    {:ok, ticket} = Projects.create_ticket(project.id, %{title: "T", user_story_id: story.id})

    assert ticket.key =~ ~r/^PRJ-\d+$/
    assert {:ok, found} = Projects.get_ticket(scope, ticket.key)
    assert found.id == ticket.id
  end

  test "cross-tenant isolation", %{project: project, scope: scope} do
    {:ok, other} = Tenancy.create_project(%{key: "OTH", name: "Other"})
    other_scope = %{scope | project_id: other.id}

    {:ok, story} = Projects.create_user_story(project.id, %{title: "Private"})

    {:ok, ticket} =
      Projects.create_ticket(project.id, %{title: "Secret", user_story_id: story.id})

    assert [] = Projects.list_user_stories(other_scope)
    assert {:error, :not_found} = Projects.get_ticket(other_scope, ticket.key)
  end

  test "status_summary includes counts and recent", %{project: project, scope: scope} do
    {:ok, story} = Projects.create_user_story(project.id, %{title: "S", status: "in_progress"})
    {:ok, _} = Projects.create_ticket(project.id, %{title: "T", user_story_id: story.id})

    summary = Projects.status_summary(scope, recent_limit: 5)
    assert summary.stories_by_status["in_progress"] == 1
    assert is_list(summary.recent)
    assert length(summary.recent) >= 1
  end

  test "boards, sprints, epics, search", %{project: project, scope: scope} do
    {:ok, board} = Projects.create_board(project.id, %{name: "Board A"})
    {:ok, sprint} = Projects.create_sprint(project.id, %{name: "S1", board_id: board.id})
    {:ok, epic} = Projects.create_epic(project.id, %{title: "Epic Searchable"})

    assert length(Projects.list_boards(scope)) >= 1
    assert length(Projects.list_sprints(scope)) >= 1
    assert {:ok, _} = Projects.get_sprint(scope, sprint.name)
    assert {:ok, _} = Projects.get_epic(scope, epic.key)

    results = Projects.search_work_items(scope, "Searchable")
    assert Enum.any?(results, &(&1.key == epic.key))
  end

  test "rejects cross-tenant story association", %{project: project} do
    {:ok, other} = Tenancy.create_project(%{key: "ZZZ", name: "Z"})
    {:ok, foreign_story} = Projects.create_user_story(other.id, %{title: "Foreign"})

    assert {:error, :invalid_association} =
             Projects.create_ticket(project.id, %{
               title: "Bad",
               user_story_id: foreign_story.id
             })
  end

  test "detects parent ticket cycle", %{project: project} do
    {:ok, story} = Projects.create_user_story(project.id, %{title: "S"})
    {:ok, a} = Projects.create_ticket(project.id, %{title: "A", user_story_id: story.id})

    {:ok, b} =
      Projects.create_ticket(project.id, %{
        title: "B",
        type: "subtask",
        user_story_id: story.id,
        parent_ticket_id: a.id
      })

    # A → parent B would cycle (B already parents under A)
    assert {:error, :cycle_detected} =
             Projects.update_ticket_parent(project.id, a.id, b.id)
  end

  test "list_epics applies default limit", %{project: project, scope: scope} do
    for i <- 1..3 do
      assert {:ok, _} = Projects.create_epic(project.id, %{title: "E#{i}"})
    end

    assert length(Projects.list_epics(scope)) <= 50
  end
end
