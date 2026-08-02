defmodule ElxMcp.Auth.RateLimitTest do
  use ExUnit.Case, async: false

  alias ElxMcp.Auth.RateLimit

  setup do
    RateLimit.setup!()
    RateLimit.reset!()
    :ok
  end

  test "allows requests under limit" do
    key = "test:ip-#{System.unique_integer()}"
    assert :ok = RateLimit.check(key, limit: 3, window_ms: 60_000)
    assert :ok = RateLimit.check(key, limit: 3, window_ms: 60_000)
    assert :ok = RateLimit.check(key, limit: 3, window_ms: 60_000)
  end

  test "returns rate_limited when over limit" do
    key = "test:burst-#{System.unique_integer()}"

    assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
    assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
    assert {:error, :rate_limited} = RateLimit.check(key, limit: 2, window_ms: 60_000)
  end

  test "counters survive spawning process exit" do
    key = "test:survive-#{System.unique_integer()}"

    parent = self()

    pid =
      spawn(fn ->
        assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
        assert :ok = RateLimit.check(key, limit: 2, window_ms: 60_000)
        send(parent, :done)
      end)

    ref = Process.monitor(pid)
    assert_receive :done
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # Counter still lives in Application-owned ETS
    assert {:error, :rate_limited} = RateLimit.check(key, limit: 2, window_ms: 60_000)
  end
end
