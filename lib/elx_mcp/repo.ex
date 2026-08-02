defmodule ElxMcp.Repo do
  @moduledoc """
  Ecto repo with tenant helpers for PostgreSQL RLS.

  * `with_tenant/2` — pins a connection and sets `app.project_id` (session GUC).
  * `with_bypass/1` — sets `app.bypass_rls=on` for the transaction (auth bootstrap, admin list).
  """

  use Ecto.Repo,
    otp_app: :elx_mcp,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` on a checked-out connection with `app.project_id` set for RLS policies.
  """
  def with_tenant(project_id, fun) when is_binary(project_id) and is_function(fun, 0) do
    checkout(fn ->
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          __MODULE__,
          "SELECT set_config('app.project_id', $1, false)",
          [project_id]
        )

      # Ensure bypass is off on this connection
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          __MODULE__,
          "SELECT set_config('app.bypass_rls', 'off', false)",
          []
        )

      fun.()
    end)
  end

  @doc """
  Runs `fun` with RLS bypass GUC for the current transaction.

  Used for API key lookup (tenant discovery), seeds helpers, and admin listing.
  Only application code should call this — never expose to untrusted input paths.
  """
  def with_bypass(fun) when is_function(fun, 0) do
    transaction(fn ->
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          __MODULE__,
          "SELECT set_config('app.bypass_rls', 'on', true)",
          []
        )

      fun.()
    end)
  end
end
