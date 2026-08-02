import Config

# -----------------------------------------------------------------------------
# Load local .env into the process environment (does not override existing vars).
# Path: project root when using Mix; optional in releases.
# -----------------------------------------------------------------------------
env_path = Path.expand(".env")

if File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value =
          value
          |> String.trim()
          |> String.trim_leading("\"")
          |> String.trim_trailing("\"")
          |> String.trim_leading("'")
          |> String.trim_trailing("'")

        if System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end)
end

# -----------------------------------------------------------------------------
# Server (all envs)
# -----------------------------------------------------------------------------
if System.get_env("PHX_SERVER") do
  config :elx_mcp, ElxMcpWeb.Endpoint, server: true
end

config :elx_mcp, ElxMcpWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  config :elx_mcp, ElxMcpWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/elx_mcp_web/router\.ex$"E,
        ~r"lib/elx_mcp_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# -----------------------------------------------------------------------------
# Database — DATABASE_URL or discrete DB_* (from .env / shell / platform)
# -----------------------------------------------------------------------------
present? = fn key ->
  case System.get_env(key) do
    nil -> false
    "" -> false
    _ -> true
  end
end

ssl_opt =
  case System.get_env("DB_SSL", "verify_none") do
    v when v in ~w(true 1 yes) -> true
    v when v in ~w(false 0 no) -> false
    "verify_none" -> [verify: :verify_none]
    other -> raise "Invalid DB_SSL=#{inspect(other)} (use true|false|verify_none)"
  end

pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

db_port = String.to_integer(System.get_env("DB_PORT", "5432"))

repo_from_parts = fn ->
  username = System.get_env("DB_USER") || System.get_env("DB_USERNAME")
  password = System.get_env("DB_PASSWORD")
  hostname = System.get_env("DB_HOST") || System.get_env("DB_HOSTNAME")

  database =
    case config_env() do
      :test ->
        partition = System.get_env("MIX_TEST_PARTITION") || ""

        System.get_env("DB_NAME_TEST") ||
          (System.get_env("DB_NAME") || "elx_mcp_test") <> partition

      :dev ->
        System.get_env("DB_NAME") || "elx_mcp_dev"

      :prod ->
        System.get_env("DB_NAME") ||
          raise """
          Missing database config. Set DATABASE_URL or DB_NAME (with DB_USER, DB_PASSWORD, DB_HOST).
          """
    end

  missing =
    Enum.reject(
      [{"DB_USER", username}, {"DB_PASSWORD", password}, {"DB_HOST", hostname}],
      fn {_k, v} -> is_binary(v) and v != "" end
    )

  if config_env() == :prod and missing != [] do
    keys = Enum.map_join(missing, ", ", fn {k, _} -> k end)

    raise """
    Missing database environment variables: #{keys}
    Set DATABASE_URL or DB_USER, DB_PASSWORD, DB_HOST, DB_NAME.
    """
  end

  # Fallbacks are generic (not project secrets). Prefer .env / env vars.
  [
    username: username || "postgres",
    password: password || "postgres",
    hostname: hostname || "localhost",
    database: database,
    port: db_port
  ]
end

repo_connection =
  cond do
    config_env() == :test and present?.("DATABASE_URL_TEST") ->
      [url: System.get_env("DATABASE_URL_TEST")]

    config_env() != :test and present?.("DATABASE_URL") ->
      [url: System.get_env("DATABASE_URL")]

    config_env() == :prod and not present?.("DATABASE_URL") ->
      # Prefer URL in prod, but allow discrete vars
      repo_from_parts.()

    true ->
      repo_from_parts.()
  end

repo_common =
  [
    ssl: ssl_opt,
    pool_size: if(config_env() == :test, do: System.schedulers_online() * 2, else: pool_size),
    socket_options: maybe_ipv6
  ]

config :elx_mcp, ElxMcp.Repo, repo_connection ++ repo_common

# -----------------------------------------------------------------------------
# Production-only app settings
# -----------------------------------------------------------------------------
if config_env() == :prod do
  mcp_cors =
    System.get_env("MCP_CORS_ORIGINS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :elx_mcp, mcp_cors_origins: mcp_cors

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :elx_mcp, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :elx_mcp, ElxMcpWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
