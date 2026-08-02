import Config

# DB credentials come from .env / env vars via config/runtime.exs
# (DB_NAME_TEST or DB_NAME + _test defaults; MIX_TEST_PARTITION suffix).
config :elx_mcp, ElxMcp.Repo, pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elx_mcp, ElxMcpWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5LNnsbfh+sh8S1242PForLQlxMw05SmcNN08jV1HXw/fNHpNj+DH4yQCJQR8ROSY",
  server: false

# In test we don't send emails
config :elx_mcp, ElxMcp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Relax MCP rate limit noise in tests; 429 plug tests override via Application.put_env
config :elx_mcp,
  allow_cors_star: true,
  mcp_cors_origins: ["*"],
  log_mcp_tools: false,
  mcp_rate_limit: [limit: 10_000, window_ms: 60_000]

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
