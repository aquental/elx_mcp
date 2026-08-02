---
module: "ElxMcp.Auth.RateLimit"
date: "2026-08-02"
problem_type: otp_issue
component: configuration
symptoms:
  - "MCP rate-limit counters reset or vanish after the first request process exits"
  - "ETS table :elx_mcp_rate_limit is gone between requests under concurrent traffic"
  - "429 never reliably trips in production despite unit tests passing"
root_cause: "Named ETS table was created (or re-created on miss) by the request process via setup!/check; when that process died, the table died with it"
severity: critical
tags: [ets, rate-limit, application-start, ownership, mcp]
---

# Rate-limit ETS must be owned by Application, not the request process

## Symptoms

- Fixed-window counters appeared to work in unit tests (same process owns the table for the test lifetime) but failed under real HTTP: each connection/request process that called `:ets.new/2` (or first `check/2` that created the table) **took ownership**.
- When the request process exited, the named table disappeared; the next request started counters from zero.
- Highest-impact residual from re-audit: rate limiting was effectively a no-op across request boundaries.

## Investigation

1. **Hypothesis**: counter logic wrong (`update_counter` race) — counters were atomic and correct within one process.
2. **Hypothesis**: test/prod config limit mismatch — not the failure mode.
3. **Root cause found**: ETS ownership. Named tables are deleted when the owning process exits. Creating the table on first `check/2` (request process) is unsafe.

```elixir
# Problematic pattern
def check(key, opts) do
  setup!()  # :ets.new from whoever calls — often Plug conn process
  :ets.update_counter(...)
end
```

## Root Cause

ETS named tables are **process-owned**. If `RateLimit.setup!/0` (or an `ensure_table!` that creates on miss) runs in a short-lived Plug/request process, the table dies with that process. Unit tests with `async: false` that call `setup!` from the test process hide the bug because the test process outlives the assertions.

## Solution

1. Call `RateLimit.setup!()` once from `Application.start/2` **before** children that serve traffic (so the **Application process** owns the table).
2. Make `setup!/0` a no-op when the table already exists.
3. On the hot path, **fail closed** if the table is missing — never recreate from a request process.

```elixir
# application.ex
def start(_type, _args) do
  :ok = ElxMcp.Auth.RateLimit.setup!()
  children = [..., ElxMcpWeb.Endpoint]
  Supervisor.start_link(children, opts)
end

# rate_limit.ex hot path
defp require_table! do
  case :ets.whereis(@table) do
    :undefined ->
      raise "ETS #{@table} missing — call RateLimit.setup!/0 from Application.start/2"
    _ -> :ok
  end
end
```

Optional: opportunistic prune of stale window keys (1% of checks) so ETS does not grow unbounded.

### Files Changed

- `lib/elx_mcp/application.ex` — `RateLimit.setup!()` at start
- `lib/elx_mcp/auth/rate_limit.ex` — no create-on-miss; prune; config-driven limit
- `test/elx_mcp/auth/rate_limit_test.exs` — spawn process that checks, exit, assert limit still bites

## Prevention

- [x] Document in Application start for any new named ETS
- [ ] Iron Law candidate: "Named ETS for request-path state must be owned by Application or a supervised process, never the request process"
- [x] Test: counter survives spawning process exit (`async: false`)
- Specific guidance: Never call `:ets.new` from Plug `call/2` for long-lived tables; use `require_table!` that raises if missing.

## Related

- `.claude/solutions/security-issues/mcp-session-bind-path-a-20260802.md` — same ownership rule for SessionBind ETS
- Plan: `.claude/plans/elx-mcp-p1-residual/plan.md` P1-T1/T2
