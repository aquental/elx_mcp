defmodule ElxMcp.MCP.ToolsTest do
  use ElxMcp.DataCase, async: true

  alias Anubis.Server.Frame
  alias ElxMcp.Auth

  alias ElxMcp.MCP.Tools.{
    GetEpic,
    GetTicket,
    ListBoards,
    ListEpics,
    ListTickets,
    ProjectStatus,
    SearchWorkItems
  }

  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "MCP", name: "MCP"})
    {:ok, key, _} = Auth.create_api_key(project.id, "m@example.com", %{})
    {:ok, epic} = Projects.create_epic(project.id, %{title: "E1", status: "to_do"})
    {:ok, story} = Projects.create_user_story(project.id, %{title: "Story", epic_id: epic.id})
    {:ok, ticket} = Projects.create_ticket(project.id, %{title: "T1", user_story_id: story.id})
    {:ok, _} = Projects.create_board(project.id, %{name: "B1"})

    frame =
      Frame.new(%{
        project_id: project.id,
        api_key_email: key.email,
        api_key_id: key.id,
        scopes: key.scopes,
        current_scope: %ElxMcp.Auth.Scope{
          project_id: project.id,
          actor_email: key.email,
          api_key_id: key.id,
          scopes: key.scopes
        }
      })

    %{frame: frame, project: project, epic: epic, story: story, ticket: ticket}
  end

  test "project_status returns summary", %{frame: frame} do
    assert {:reply, response, ^frame} = ProjectStatus.execute(%{recent_limit: 5}, frame)
    assert response.type == :tool
    assert response.isError == false
  end

  test "list_epics returns epics", %{frame: frame} do
    assert {:reply, response, ^frame} = ListEpics.execute(%{}, frame)
    assert response.isError == false
  end

  test "get_epic and get_ticket", %{frame: frame, epic: epic, ticket: ticket} do
    assert {:reply, r1, _} = GetEpic.execute(%{key: epic.key}, frame)
    assert r1.isError == false

    assert {:reply, r2, _} = GetTicket.execute(%{key: ticket.key}, frame)
    assert r2.isError == false

    # nested associations encoded (not dropped)
    text = hd(r2.content)["text"]
    assert text =~ "user_story" or text =~ ticket.title
  end

  test "list_tickets not found on bad story_key", %{frame: frame} do
    assert {:reply, response, _} = ListTickets.execute(%{story_key: "NOPE-999"}, frame)
    assert response.isError == true
  end

  test "list_boards and search", %{frame: frame} do
    assert {:reply, r1, _} = ListBoards.execute(%{}, frame)
    assert r1.isError == false

    assert {:reply, r2, _} = SearchWorkItems.execute(%{q: "Story"}, frame)
    assert r2.isError == false
  end

  test "unauthorized without assigns" do
    frame = Frame.new(%{})
    assert {:reply, response, _} = ProjectStatus.execute(%{}, frame)
    assert response.isError == true
  end

  test "unauthorized when scopes missing project:read", %{project: project} do
    frame =
      Frame.new(%{
        project_id: project.id,
        api_key_email: "x@y.com",
        api_key_id: Ecto.UUID.generate(),
        scopes: ["project:write"]
      })

    assert {:reply, response, _} = ProjectStatus.execute(%{}, frame)
    assert response.isError == true
  end
end
