defmodule ElxMcp.CollaborationTest do
  use ElxMcp.DataCase, async: true

  alias ElxMcp.Auth.Scope
  alias ElxMcp.Collaboration
  alias ElxMcp.Projects
  alias ElxMcp.Tenancy

  setup do
    {:ok, project} = Tenancy.create_project(%{key: "COL", name: "Collab"})

    write_scope = %Scope{
      project_id: project.id,
      actor_email: "c@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read", "project:write"]
    }

    read_scope = %{write_scope | scopes: ["project:read"]}

    {:ok, story} = Projects.create_user_story(write_scope, %{title: "S"})
    {:ok, ticket} = Projects.create_ticket(write_scope, %{title: "T", user_story_id: story.id})

    %{project: project, ticket: ticket, scope: read_scope, write_scope: write_scope}
  end

  test "comments and changelog", %{ticket: ticket, scope: scope, write_scope: write_scope} do
    assert {:ok, _} =
             Collaboration.create_comment(write_scope, %{
               commentable_type: "ticket",
               commentable_id: ticket.id,
               author_email: "c@example.com",
               body: "hello"
             })

    assert [_] = Collaboration.list_comments(scope, "ticket", ticket.id)

    assert {:ok, _} =
             Collaboration.record_changelog(write_scope, %{
               entity_type: "ticket",
               entity_id: ticket.id,
               field: "status",
               old_value: "to_do",
               new_value: "done",
               actor_email: "c@example.com"
             })

    assert [_] = Collaboration.list_changelog(scope, "ticket", ticket.id)
  end

  test "worklog updates ticket time", %{ticket: ticket, write_scope: write_scope} do
    assert {:ok, _} =
             Collaboration.create_worklog(write_scope, ticket.id, %{
               author_email: "c@example.com",
               time_spent_seconds: 3600
             })

    assert {:ok, _} =
             Collaboration.create_worklog(write_scope, ticket.id, %{
               author_email: "c@example.com",
               time_spent_seconds: 1800
             })

    reloaded = ElxMcp.Repo.get!(ElxMcp.Projects.Ticket, ticket.id)
    assert reloaded.time_spent_seconds == 5400
  end

  test "attachment create and cross-tenant isolation", %{
    ticket: ticket,
    scope: scope,
    write_scope: write_scope
  } do
    assert {:ok, _} =
             Collaboration.create_attachment(write_scope, %{
               attachable_type: "ticket",
               attachable_id: ticket.id,
               filename: "a.txt",
               storage_path: "/tmp/a.txt"
             })

    assert {:ok, _} =
             Collaboration.create_comment(write_scope, %{
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

  test "create_comment requires project:write", %{ticket: ticket, scope: scope} do
    assert {:error, :forbidden} =
             Collaboration.create_comment(scope, %{
               commentable_type: "ticket",
               commentable_id: ticket.id,
               author_email: "c@example.com",
               body: "nope"
             })
  end

  test "create_comment rejects foreign entity id", %{write_scope: write_scope} do
    {:ok, other} = Tenancy.create_project(%{key: "FOR", name: "Foreign"})

    other_write = %Scope{
      project_id: other.id,
      actor_email: "o@example.com",
      api_key_id: Ecto.UUID.generate(),
      scopes: ["project:read", "project:write"]
    }

    {:ok, story} = Projects.create_user_story(other_write, %{title: "S"})

    {:ok, foreign_ticket} =
      Projects.create_ticket(other_write, %{title: "T", user_story_id: story.id})

    assert {:error, :invalid_association} =
             Collaboration.create_comment(write_scope, %{
               commentable_type: "ticket",
               commentable_id: foreign_ticket.id,
               body: "cross"
             })
  end

  test "forces author_email from scope", %{ticket: ticket, write_scope: write_scope} do
    assert {:ok, comment} =
             Collaboration.create_comment(write_scope, %{
               commentable_type: "ticket",
               commentable_id: ticket.id,
               author_email: "spoofed@evil.com",
               body: "hi"
             })

    assert comment.author_email == write_scope.actor_email
  end
end
