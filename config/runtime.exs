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
        # No exotic regex options — CI uses Elixir 1.18 (option `E` is not portable)
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"priv/gettext/.*\.po$",
        ~r"lib/elx_mcp_web/router\.ex$",
        ~r"lib/elx_mcp_web/(controllers|live|components)/.*\.(ex|heex)$"
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

# Prod/dev default: verified TLS. Override with DB_SSL=verify_none only for loopback lab.
ssl_default = "true"

# Decode first CERTIFICATE in a PEM file to DER (for pin / cacerts).
pem_to_ders = fn path ->
  path
  |> File.read!()
  |> :public_key.pem_decode()
  |> Enum.flat_map(fn
    {:Certificate, der, :not_encrypted} -> [der]
    _ -> []
  end)
end

# Self-signed server certs (no CA:true) fail OTP default trust; pin by SHA-256 DER.
# Accept only if the peer cert fingerprint matches the pinned PEM (anti-MITM).
ssl_pin_opts = fn ca_path, sni ->
  ders = pem_to_ders.(ca_path)

  if ders == [] do
    raise "DB_SSL_CA has no CERTIFICATE entries: #{ca_path}"
  end

  # Compare decoded OTP certs (DER re-encode is not stable across OTP versions).
  pinned_otp = Enum.map(ders, &:public_key.pkix_decode_cert(&1, :otp))

  verify_fun = fn
    cert, {:bad_cert, :selfsigned_peer}, state ->
      if Enum.any?(pinned_otp, &(&1 == cert)) do
        {:valid, state}
      else
        {:fail, {:bad_cert, :selfsigned_peer}}
      end

    _cert, {:bad_cert, reason}, _state ->
      {:fail, reason}

    _cert, {:extension, _}, state ->
      {:unknown, state}

    _cert, :valid, state ->
      {:valid, state}

    _cert, :valid_peer, state ->
      {:valid, state}
  end

  [
    verify: :verify_peer,
    cacerts: ders,
    depth: 0,
    verify_fun: {verify_fun, nil},
    server_name_indication: String.to_charlist(sni),
    customize_hostname_check: [
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    ]
  ]
end

ssl_opt =
  case System.get_env("DB_SSL", ssl_default) do
    v when v in ~w(true 1 yes) ->
      ca = System.get_env("DB_SSL_CA")

      sni =
        System.get_env("DB_SSL_HOSTNAME") ||
          System.get_env("DB_HOST") ||
          System.get_env("DB_HOSTNAME") ||
          "localhost"

      cond do
        is_binary(ca) and ca != "" ->
          ca_path = Path.expand(ca)

          unless File.exists?(ca_path) do
            raise """
            DB_SSL_CA file not found: #{ca_path}
            Set DB_SSL_CA to a PEM path (self-signed server cert or private CA).
            """
          end

          ssl_pin_opts.(ca_path, sni)

        true ->
          # Public CA roots (Let's Encrypt, commercial CAs, etc.)
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(sni),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
      end

    v when v in ~w(false 0 no) ->
      false

    "verify_none" ->
      if config_env() == :prod do
        IO.warn("""
        DB_SSL=verify_none in production disables TLS certificate verification (MITM risk).
        Prefer DB_SSL=true with DB_SSL_CA (or system roots for public CAs).
        """)
      end

      [verify: :verify_none]

    other ->
      raise "Invalid DB_SSL=#{inspect(other)} (use true|false|verify_none)"
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

  # Never fall back to postgres/postgres/localhost — that can silently hit a real
  # server with default credentials. Require explicit DB_* (or use DATABASE_URL*).
  missing =
    Enum.reject(
      [
        {"DB_USER (or DB_USERNAME)", username},
        {"DB_PASSWORD", password},
        {"DB_HOST (or DB_HOSTNAME)", hostname}
      ],
      fn {_k, v} -> is_binary(v) and v != "" end
    )

  if missing != [] do
    keys = Enum.map_join(missing, ", ", fn {k, _} -> k end)

    raise """
    Missing database environment variables: #{keys}

    Set discrete vars (loaded from .env by this file, or the shell / platform):

      DB_USER=...
      DB_PASSWORD=...
      DB_HOST=...
      DB_NAME=elx_mcp_dev          # optional in dev (default elx_mcp_dev)
      DB_NAME_TEST=elx_mcp_test    # optional in test (default elx_mcp_test)
      DB_PORT=5432                 # optional (default 5432)

    Or a single URL:

      DATABASE_URL=ecto://USER:PASSWORD@HOST:5432/elx_mcp_dev
      DATABASE_URL_TEST=ecto://USER:PASSWORD@HOST:5432/elx_mcp_test
    """
  end

  [
    username: username,
    password: password,
    hostname: hostname,
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
    socket_options: maybe_ipv6,
    # Reset tenant GUC on every new pool connection (W2)
    after_connect: {ElxMcp.Repo, :after_connect, []}
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
