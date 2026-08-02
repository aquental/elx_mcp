defmodule ElxMcp.Auth.RateLimit do
  @moduledoc """
  Simple ETS sliding-window rate limiter for MCP auth (per IP).
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
  """
  def check(key, opts \\ []) when is_binary(key) do
    setup!()
    limit = Keyword.get(opts, :limit, @default_limit)
    window = Keyword.get(opts, :window_ms, @window_ms)
    now = System.system_time(:millisecond)
    cutoff = now - window

    case :ets.lookup(@table, key) do
      [{^key, times}] ->
        recent = Enum.filter(times, &(&1 > cutoff))

        if length(recent) >= limit do
          :ets.insert(@table, {key, recent})
          {:error, :rate_limited}
        else
          :ets.insert(@table, {key, [now | recent]})
          :ok
        end

      [] ->
        :ets.insert(@table, {key, [now]})
        :ok
    end
  end
end
