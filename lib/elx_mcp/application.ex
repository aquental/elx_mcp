defmodule ElxMcp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Application process owns named ETS tables so they survive request processes.
    :ok = ElxMcp.Auth.RateLimit.setup!()
    :ok = ElxMcp.Auth.SessionBind.setup!()

    children = [
      ElxMcpWeb.Telemetry,
      ElxMcp.Repo,
      {DNSCluster, query: Application.get_env(:elx_mcp, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElxMcp.PubSub},
      {ElxMcp.MCP.Server, transport: :streamable_http},
      # Start to serve requests, typically the last entry
      ElxMcpWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElxMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ElxMcpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
