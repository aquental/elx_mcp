defmodule ElxMcp.Auth.RateLimitTest do
  use ExUnit.Case, async: false

  alias ElxMcp.Auth.RateLimit

  setup do
    RateLimit.reset!()
    :ok
  end

  test "allows requests under limit" do
    assert :ok = RateLimit.check("test:ip", limit: 3, window_ms: 60_000)
    assert :ok = RateLimit.check("test:ip", limit: 3, window_ms: 60_000)
    assert :ok = RateLimit.check("test:ip", limit: 3, window_ms: 60_000)
  end

  test "returns rate_limited when over limit" do
    key = "test:burst-#{System.unique_integer()}"

    assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
    assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
    assert {:error, :rate_limited} = RateLimit.check(key, limit: 2, window_ms: 60_000)
  end
end
