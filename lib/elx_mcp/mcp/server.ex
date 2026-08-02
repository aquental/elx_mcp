defmodule ElxMcp.MCP.Server do
  @moduledoc """
  MCP server exposing project status (read-only tools and resources).
  """

  use Anubis.Server,
    name: "ElxMCP Project Status",
    version: "0.2.0",
    capabilities: [:tools, :resources]

  # Tools
  component(ElxMcp.MCP.Tools.ProjectStatus)
  component(ElxMcp.MCP.Tools.ListEpics)
  component(ElxMcp.MCP.Tools.GetEpic)
  component(ElxMcp.MCP.Tools.ListUserStories)
  component(ElxMcp.MCP.Tools.GetUserStory)
  component(ElxMcp.MCP.Tools.ListTickets)
  component(ElxMcp.MCP.Tools.GetTicket)
  component(ElxMcp.MCP.Tools.SearchWorkItems)
  component(ElxMcp.MCP.Tools.ListSprints)
  component(ElxMcp.MCP.Tools.ListBoards)
  component(ElxMcp.MCP.Tools.ListComments)
  component(ElxMcp.MCP.Tools.ListChangelog)

  # Resources
  component(ElxMcp.MCP.Resources.ProjectStatus)
  component(ElxMcp.MCP.Resources.Epic)
  component(ElxMcp.MCP.Resources.UserStory)
  component(ElxMcp.MCP.Resources.Ticket)
  component(ElxMcp.MCP.Resources.Sprint)

  @impl true
  def init(_client_info, frame) do
    {:ok, frame}
  end
end
