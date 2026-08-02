defmodule ElxMcp.Repo do
  @moduledoc """
  Ecto repo with tenant helpers for PostgreSQL RLS.

  `with_tenant/2` sets `app.project_id` with **SET LOCAL** inside a transaction
  (outer call only). Nested calls with the **same** project_id skip GUC round-trips.
  Nested calls with a **different** project_id re-set the GUC for that scope.

  On SQL errors inside `fun`, the nested TX may be aborted — we never run clear
  SQL *after* `fun` inside that TX. After the nested TX returns, we clear the
  GUC outside it so Ecto Sandbox (outer open TX + SAVEPOINT) does not leak tenant
  to later queries on the same connection.
  """

  use Ecto.Repo,
    otp_app: :elx_mcp,
    adapter: Ecto.Adapters.Postgres

  @depth_key {__MODULE__, :tenant_depth}
  @project_key {__MODULE__, :tenant_project_id}

  @doc """
  Pool `after_connect` hook: force empty tenant GUC on new connections.

  Defense-in-depth if a session-level set ever leaks onto a pooled connection.
  """
  def after_connect(conn) do
    Postgrex.query!(conn, "SELECT set_config('app.project_id', '', false)", [])
    :ok
  end

  @doc """
  Runs `fun` with RLS tenant GUC `app.project_id` set.

  Returns the value of `fun.()`. On transaction abort, returns `{:error, reason}`.
  """
  def with_tenant(project_id, fun) when is_binary(project_id) and is_function(fun, 0) do
    depth = Process.get(@depth_key, 0)
    Process.put(@depth_key, depth + 1)

    try do
      if depth == 0 do
        # Do not clear GUC inside the nested TX after fun: if fun caused a SQL
        # error the TX is aborted and further SQL raises. Clear *after* the
        # nested TX returns so Sandbox outer TX does not retain LOCAL GUC.
        # try/after ensures clear even when transaction/1 re-raises.
        try do
          case transaction(fn ->
                 Process.put(@project_key, project_id)
                 set_tenant_guc!(project_id)
                 fun.()
               end) do
            {:ok, value} -> value
            {:error, reason} -> {:error, reason}
          end
        after
          safe_clear_tenant_guc()
        end
      else
        current = Process.get(@project_key)

        if current == project_id do
          fun.()
        else
          prev = current
          Process.put(@project_key, project_id)
          set_tenant_guc!(project_id)

          try do
            fun.()
          after
            # Always restore process dict; GUC restore is best-effort if TX aborted
            if prev do
              Process.put(@project_key, prev)
              safe_set_tenant_guc(prev)
            else
              Process.delete(@project_key)
            end
          end
        end
      end
    after
      Process.put(@depth_key, depth)

      if depth == 0 do
        Process.delete(@project_key)
      end
    end
  end

  defp set_tenant_guc!(project_id) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        __MODULE__,
        "SELECT set_config('app.project_id', $1, true)",
        [project_id]
      )

    :ok
  end

  defp safe_set_tenant_guc(project_id) do
    Ecto.Adapters.SQL.query(
      __MODULE__,
      "SELECT set_config('app.project_id', $1, true)",
      [project_id]
    )

    :ok
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      _ = e
      :ok
  end

  defp safe_clear_tenant_guc do
    Ecto.Adapters.SQL.query(
      __MODULE__,
      "SELECT set_config('app.project_id', '', true)",
      []
    )

    :ok
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      _ = e
      :ok
  end
end
