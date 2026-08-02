defmodule ElxMcp.Catalog do
  @moduledoc """
  Shared allowlists for statuses, priorities, and entity types (Jira-like).
  """

  @statuses ~w(backlog to_do in_progress in_review done cancelled)
  @priorities ~w(lowest low medium high highest)
  @ticket_types ~w(task bug subtask spike chore)
  @sprint_statuses ~w(future active closed)
  @board_types ~w(scrum kanban)
  @linkable_types ~w(epic user_story ticket)
  @entity_types ~w(epic user_story ticket sprint)
  @scopes ~w(project:read project:write)

  def statuses, do: @statuses
  def priorities, do: @priorities
  def ticket_types, do: @ticket_types
  def sprint_statuses, do: @sprint_statuses
  def board_types, do: @board_types
  def linkable_types, do: @linkable_types
  def entity_types, do: @entity_types
  def scopes, do: @scopes

  def valid_status?(value) when is_binary(value), do: value in @statuses
  def valid_status?(_), do: false

  def valid_priority?(value) when is_binary(value), do: value in @priorities
  def valid_priority?(_), do: false
end
