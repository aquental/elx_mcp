defmodule ElxMcp.Auth.SessionBind do
  @moduledoc """
  Binds MCP session IDs to the authenticating principal (`api_key_id` + `project_id`).

  Protects session lifecycle (DELETE / SSE GET) from cross-principal hijack.
  Tool data paths re-auth every request independently.

  Entries expire after `@ttl_ms` (default 30 minutes, aligned with Anubis idle timeout).
  """

  @table :elx_mcp_session_bind
  # Match typical Anubis session_idle_timeout (30 min)
  @ttl_ms 1_800_000

  def setup! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        @table
    end

    :ok
  end

  @doc """
  Bind `session_id` to the principal on first use.

  Returns:
  - `:ok` if newly bound or already bound to the same principal
  - `{:error, :forbidden}` if bound to another principal
  - `{:error, :invalid_session}` if args invalid
  """
  def bind_if_new(session_id, api_key_id, project_id)
      when is_binary(session_id) and session_id != "" and not is_nil(api_key_id) and
             not is_nil(project_id) do
    require_table!()
    maybe_prune()
    now = System.system_time(:millisecond)
    owner = {api_key_id, project_id, now}

    case lookup_live(session_id, now) do
      :missing ->
        case :ets.insert_new(@table, {session_id, owner}) do
          true ->
            :ok

          false ->
            verify_owner(session_id, api_key_id, project_id)
        end

      {:ok, ^api_key_id, ^project_id} ->
        # Refresh TTL on activity
        :ets.insert(@table, {session_id, owner})
        :ok

      {:ok, _other_key, _other_proj} ->
        {:error, :forbidden}
    end
  end

  def bind_if_new(_, _, _), do: {:error, :invalid_session}

  @doc """
  Verify the caller owns a **currently bound** session (fail-closed).

  Unbound or expired sessions return `{:error, :not_found}`.
  Use for DELETE / GET lifecycle. POST uses `bind_if_new/3` instead.
  """
  def verify_owner(session_id, api_key_id, project_id)
      when is_binary(session_id) and session_id != "" and not is_nil(api_key_id) and
             not is_nil(project_id) do
    require_table!()
    now = System.system_time(:millisecond)

    case lookup_live(session_id, now) do
      :missing -> {:error, :not_found}
      {:ok, ^api_key_id, ^project_id} -> :ok
      {:ok, _, _} -> {:error, :forbidden}
    end
  end

  def verify_owner(_, _, _), do: {:error, :invalid_session}

  @doc false
  def unbind(session_id) when is_binary(session_id) do
    require_table!()
    :ets.delete(@table, session_id)
    :ok
  end

  @doc false
  def reset! do
    require_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup_live(session_id, now) do
    case :ets.lookup(@table, session_id) do
      [] ->
        :missing

      [{^session_id, {api_key_id, project_id, bound_at}}] ->
        if now - bound_at > @ttl_ms do
          :ets.delete(@table, session_id)
          :missing
        else
          {:ok, api_key_id, project_id}
        end

      # Legacy 2-tuple entries from earlier SessionBind (no timestamp)
      [{^session_id, {api_key_id, project_id}}] ->
        {:ok, api_key_id, project_id}
    end
  end

  defp maybe_prune do
    if :rand.uniform(100) == 1 do
      now = System.system_time(:millisecond)
      cutoff = now - @ttl_ms

      :ets.foldl(
        fn
          {sid, {_k, _p, bound_at}}, acc when is_integer(bound_at) and bound_at < cutoff ->
            :ets.delete(@table, sid)
            acc

          _, acc ->
            acc
        end,
        :ok,
        @table
      )
    end

    :ok
  end

  defp require_table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise "ETS #{@table} missing — call SessionBind.setup!/0 from Application.start/2"

      _ ->
        :ok
    end
  end
end
