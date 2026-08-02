defmodule ElxMcp.Repo do
  use Ecto.Repo,
    otp_app: :elx_mcp,
    adapter: Ecto.Adapters.Postgres
end
