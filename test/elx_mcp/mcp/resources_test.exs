defmodule ElxMcp.MCP.ResourcesTest do
  use ElxMcp.DataCase, async: true

  alias Anubis.Server.Frame
  alias ElxMcp.Auth
  alias ElxMcp.MCP.Resources
  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "RES", name: "Resources"})
    {:ok, key, _} = Auth.create_api_key(project.id, "r@example.com", %{})

    write_scope = %ElxMcp.Auth.Scope{
      project_id: project.id,
      actor_email: key.email,
      api_key_id: key.id,
      scopes: ["project:read", "project:write"]
    }

    {:ok, epic} = Projects.create_epic(write_scope, %{title: "Epic R"})
    {:ok, story} = Projects.create_user_story(write_scope, %{title: "Story R", epic_id: epic.id})

    {:ok, ticket} =
      Projects.create_ticket(write_scope, %{title: "Ticket R", user_story_id: story.id})

    {:ok, board} = Projects.create_board(write_scope, %{name: "Board R"})
    {:ok, sprint} = Projects.create_sprint(write_scope, %{name: "Sprint R", board_id: board.id})

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

    %{
      frame: frame,
      epic: epic,
      story: story,
      ticket: ticket,
      sprint: sprint
    }
  end

  test "epic resource happy path", %{frame: frame, epic: epic} do
    assert {:reply, res, _} = Resources.Epic.read(%{"key" => epic.key}, frame)
    assert res.type == :resource
    text = resource_text(res)
    assert text =~ epic.key
    assert text =~ "Epic R"
  end

  test "epic resource not_found", %{frame: frame} do
    assert {:reply, res, _} = Resources.Epic.read(%{"key" => "RES-9999"}, frame)
    assert res.type == :resource
    assert resource_text(res) =~ "not_found"
  end

  test "user_story resource happy path", %{frame: frame, story: story} do
    assert {:reply, res, _} = Resources.UserStory.read(%{"key" => story.key}, frame)
    assert res.type == :resource
    assert resource_text(res) =~ story.key
  end

  test "user_story resource not_found", %{frame: frame} do
    assert {:reply, res, _} = Resources.UserStory.read(%{"key" => "RES-9998"}, frame)
    assert resource_text(res) =~ "not_found"
  end

  test "ticket resource happy path", %{frame: frame, ticket: ticket} do
    assert {:reply, res, _} = Resources.Ticket.read(%{"key" => ticket.key}, frame)
    assert res.type == :resource
    assert resource_text(res) =~ ticket.key
  end

  test "ticket resource not_found", %{frame: frame} do
    assert {:reply, res, _} = Resources.Ticket.read(%{"key" => "RES-9997"}, frame)
    assert resource_text(res) =~ "not_found"
  end

  test "sprint resource happy path", %{frame: frame, sprint: sprint} do
    assert {:reply, res, _} = Resources.Sprint.read(%{"id_or_name" => sprint.name}, frame)
    assert res.type == :resource
    text = resource_text(res)
    assert text =~ "Sprint R" or text =~ sprint.id
  end

  test "sprint resource not_found", %{frame: frame} do
    assert {:reply, res, _} = Resources.Sprint.read(%{"id_or_name" => "no-such-sprint"}, frame)
    assert resource_text(res) =~ "not_found"
  end

  test "unauthorized without scope" do
    frame = Frame.new(%{})
    assert {:reply, res, _} = Resources.Epic.read(%{"key" => "X-1"}, frame)
    assert resource_text(res) =~ "unauthorized"
  end

  defp resource_text(res) do
    case res do
      %{contents: %{"text" => text}} when is_binary(text) -> text
      %{contents: %{text: text}} when is_binary(text) -> text
      %{content: [%{"text" => text} | _]} -> text
      other -> inspect(other)
    end
  end
end
