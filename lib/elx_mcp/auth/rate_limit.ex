defmodule ElxMcp.Auth.RateLimit do
  @moduledoc """
  Single-node ETS fixed-window rate limiter for MCP auth (per key, typically IP).

  Not multi-node-safe. For multi-node, put a shared limiter (Redis/Hammer) in front.
  """

  @table :elx_mcp_rate_limit
  @default_limit 120
  @window_ms 60_000

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
  """
  def check(key, opts \\ []) when is_binary(key) do
    setup!()
    limit = Keyword.get(opts, :limit, @default_limit)
    window = Keyword.get(opts, :window_ms, @window_ms)
    now = System.system_time(:millisecond)
    bucket = div(now, window)
    ets_key = {key, bucket}

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
    setup!()
    :ets.delete_all_objects(@table)
    :ok
  end
end
