defmodule ElxMcp.Auth.RateLimit do
  @moduledoc """
  Single-node ETS fixed-window rate limiter for MCP auth (per key, typically IP).

  The Application process owns the named ETS table (see `setup!/0` from
  `ElxMcp.Application`). Not multi-node-safe — put Redis/Hammer in front for
  multi-node deployments.
  """

  @table :elx_mcp_rate_limit
  @default_limit 120
  @window_ms 60_000

  @doc """
  Ensure the named ETS table exists. Safe to call repeatedly (no-op if present).

  Prefer calling from `Application.start/2` so the Application process owns the table.
  """
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
  Returns `:ok` or `{:error, :rate_limited}`.

  Uses an atomic per-window counter (`:ets.update_counter/4`).
  Assumes the table already exists (Application or test setup).
  """
  def check(key, opts \\ []) when is_binary(key) do
    require_table!()
    limit = Keyword.get(opts, :limit, default_limit())
    window = Keyword.get(opts, :window_ms, default_window_ms())
    now = System.system_time(:millisecond)
    bucket = div(now, window)
    ets_key = {key, bucket}

    maybe_prune(bucket)

    # {ets_key, count} — atomic increment
    count = :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0})

    if count > limit do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc false
  def reset! do
    require_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp default_limit do
    conf = Application.get_env(:elx_mcp, :mcp_rate_limit, [])
    Keyword.get(conf, :limit, @default_limit)
  end

  defp default_window_ms do
    conf = Application.get_env(:elx_mcp, :mcp_rate_limit, [])
    Keyword.get(conf, :window_ms, @window_ms)
  end

  # Fail closed: never create the table from a request process (ownership bug).
  defp require_table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise "ETS #{@table} missing — call RateLimit.setup!/0 from Application.start/2"

      _ ->
        :ok
    end
  end

  # Opportunistic delete of buckets older than 2 windows (1% of checks).
  defp maybe_prune(current_bucket) do
    if :rand.uniform(100) == 1 do
      cutoff = current_bucket - 2

      :ets.select_delete(@table, [
        {{{:"$1", :"$2"}, :"$3"}, [{:<, :"$2", cutoff}], [true]}
      ])
    end

    :ok
  end
end
