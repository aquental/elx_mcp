defmodule ElxMcp.CollaborationTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Auth.Scope
  alias ElxMcp.Collaboration
  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "COL", name: "Collab"})
    {:ok, story} = Projects.create_user_story(project.id, %{title: "S"})
    {:ok, ticket} = Projects.create_ticket(project.id, %{title: "T", user_story_id: story.id})

    scope = %Scope{
      project_id: project.id,
      actor_email: "c@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read"]
    }

    %{project: project, ticket: ticket, scope: scope}
  end

  test "comments and changelog", %{project: project, ticket: ticket, scope: scope} do
    assert {:ok, _} =
             Collaboration.create_comment(project.id, %{
               commentable_type: "ticket",
               commentable_id: ticket.id,
               author_email: "c@example.com",
               body: "hello"
             })

    assert [_] = Collaboration.list_comments(scope, "ticket", ticket.id)

    assert {:ok, _} =
             Collaboration.record_changelog(project.id, %{
               entity_type: "ticket",
               entity_id: ticket.id,
               field: "status",
               old_value: "to_do",
               new_value: "done",
               actor_email: "c@example.com"
             })

    assert [_] = Collaboration.list_changelog(scope, "ticket", ticket.id)
  end

  test "worklog updates ticket time", %{project: project, ticket: ticket} do
    assert {:ok, _} =
             Collaboration.create_worklog(project.id, ticket.id, %{
               author_email: "c@example.com",
               time_spent_seconds: 3600
             })

    assert {:ok, _} =
             Collaboration.create_worklog(project.id, ticket.id, %{
               author_email: "c@example.com",
               time_spent_seconds: 1800
             })

    reloaded = ElxMcp.Repo.get!(ElxMcp.Projects.Ticket, ticket.id)
    assert reloaded.time_spent_seconds == 5400
  end

  test "attachment create and cross-tenant isolation", %{
    project: project,
    ticket: ticket,
    scope: scope
  } do
    assert {:ok, _} =
             Collaboration.create_attachment(project.id, %{
               attachable_type: "ticket",
               attachable_id: ticket.id,
               filename: "a.txt",
               storage_path: "/tmp/a.txt"
             })

    assert {:ok, _} =
             Collaboration.create_comment(project.id, %{
               commentable_type: "ticket",
               commentable_id: ticket.id,
               author_email: "c@example.com",
               body: "iso"
             })

    {:ok, other} = ElxMcp.Tenancy.create_project(%{key: "ISO", name: "Iso"})

    other_scope = %Scope{
      project_id: other.id,
      actor_email: "x@y.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read"]
    }

    assert [] = Collaboration.list_comments(other_scope, "ticket", ticket.id)
    assert [] = Collaboration.list_changelog(other_scope, "ticket", ticket.id)
    assert length(Collaboration.list_comments(scope, "ticket", ticket.id)) >= 1
  end
end
