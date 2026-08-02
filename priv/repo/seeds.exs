# Seeds demo project for ElxMCP MVP

alias ElxMcp.{Auth, Collaboration, Projects, Tenancy}

{:ok, project} =
  case Tenancy.get_project_by_key("DEMO") do
    nil ->
      Tenancy.create_project(%{key: "DEMO", name: "Demo Project", description: "Seeded demo"})

    existing ->
      {:ok, existing}
  end

write_scope = %ElxMcp.Auth.Scope{
  project_id: project.id,
  actor_email: "seed@example.com",
  api_key_id: Ecto.UUID.generate(),
  scopes: ["project:read", "project:write"]
}

scope = %{write_scope | scopes: ["project:read"]}

{:ok, board} =
  case Projects.list_boards(scope) do
    [] -> Projects.create_board(write_scope, %{name: "Main Board", type: "scrum"})
    [b | _] -> {:ok, b}
  end

{:ok, sprint} =
  if Projects.list_sprints(scope) == [] do
    Projects.create_sprint(write_scope, %{
      name: "Sprint 1",
      status: "active",
      board_id: board.id,
      goal: "Ship MCP MVP"
    })
  else
    {:ok, hd(Projects.list_sprints(scope))}
  end

{:ok, epic} =
  if Projects.list_epics(scope) == [] do
    Projects.create_epic(write_scope, %{
      title: "MCP Project Status",
      description: "Expose project status via MCP",
      status: "in_progress",
      priority: "high",
      owner_email: "pm@example.com"
    })
  else
    {:ok, hd(Projects.list_epics(scope))}
  end

stories = Projects.list_user_stories(scope)

{story1, story2} =
  case stories do
    [s1, s2 | _] ->
      {s1, s2}

    _ ->
      {:ok, s1} =
        Projects.create_user_story(write_scope, %{
          title: "As an agent I can read project status",
          epic_id: epic.id,
          status: "in_progress",
          story_points: 5,
          assignee_email: "dev@example.com",
          sprint_id: sprint.id,
          board_id: board.id
        })

      {:ok, s2} =
        Projects.create_user_story(write_scope, %{
          title: "As a user I can manage API keys via mix task",
          status: "to_do",
          story_points: 3,
          reporter_email: "dev@example.com"
        })

      {s1, s2}
  end

if Projects.list_tickets(scope) == [] do
  {:ok, t1} =
    Projects.create_ticket(write_scope, %{
      title: "Implement schemas",
      user_story_id: story1.id,
      type: "task",
      status: "done",
      assignee_email: "dev@example.com"
    })

  {:ok, _t2} =
    Projects.create_ticket(write_scope, %{
      title: "Implement MCP tools",
      user_story_id: story1.id,
      type: "task",
      status: "in_progress",
      assignee_email: "dev@example.com"
    })

  {:ok, _t3} =
    Projects.create_ticket(write_scope, %{
      title: "Add isolation tests",
      user_story_id: story1.id,
      type: "task",
      status: "to_do"
    })

  {:ok, _t4} =
    Projects.create_ticket(write_scope, %{
      title: "Document mix task",
      user_story_id: story2.id,
      type: "chore",
      status: "backlog"
    })

  {:ok, _} =
    Collaboration.create_comment(write_scope, %{
      commentable_type: "ticket",
      commentable_id: t1.id,
      author_email: "dev@example.com",
      body: "Schemas look good."
    })

  {:ok, _} =
    Collaboration.record_changelog(write_scope, %{
      entity_type: "ticket",
      entity_id: t1.id,
      actor_email: "dev@example.com",
      field: "status",
      old_value: "in_progress",
      new_value: "done"
    })
end

if Auth.list_api_keys(project.id) == [] do
  {:ok, _key, plaintext} =
    Auth.create_api_key(project.id, "demo@example.com", %{name: "Demo seed key"})

  IO.puts("""
  === Demo API key (dev only — shown once) ===
  X-API-Key: #{plaintext}
  X-Email:   demo@example.com
  Project:   #{project.key}
  ===========================================
  """)
else
  IO.puts("Seeds: project #{project.key} already has data; skipped key generation.")
end
