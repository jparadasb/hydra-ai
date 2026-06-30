import Config

# Worker join token (shared secret). Applies in every environment, resolved at boot. Unset or
# empty => the coordinator accepts any worker that reaches it (fine on loopback, NOT for a
# public tunnel). See Coordinator.JoinAuth.
case System.get_env("HYDRA_JOIN_TOKEN") do
  token when token in [nil, ""] -> :ok
  token -> config :coordinator, :join_token, token
end

# Require every worker to authenticate with an Ed25519 device key (Coordinator.DeviceAuth).
# Recommended for a public coordinator; rejects token-only / open connections.
config :coordinator, :require_device_auth, System.get_env("HYDRA_REQUIRE_DEVICE_AUTH") == "true"

# Gateway access key for the OpenAI-compatible HTTP front-door (Coordinator.ApiRouter). This is
# NOT a provider token — it only gates who may submit jobs. Unset/empty => the door is open
# (fine on loopback, NOT for a public tunnel). Callers send `Authorization: Bearer <token>`.
case System.get_env("HYDRA_API_TOKEN") do
  token when token in [nil, ""] -> :ok
  token -> config :coordinator, :api_token, token
end

# Routing capability for the front-door's chat requests. Workers run a chat completion for any
# capability they advertise, so this must match a capability the connected workers serve. Unset
# => "chat". (Current built-in adapters advertise e.g. "text.extract_json".)
case System.get_env("HYDRA_API_CAPABILITY") do
  cap when cap in [nil, ""] -> :ok
  cap -> config :coordinator, :api_capability, cap
end

# Production database + Oban configuration, resolved at boot from the environment.
# DB_ADAPTER selects the backend (and MUST match the value used when the release was built,
# since the repo adapter is compiled in — see Coordinator.Repo).
if config_env() == :prod do
  case System.get_env("DB_ADAPTER", "sqlite3") do
    adapter when adapter in ["postgres", "postgresql"] ->
      database_url =
        System.get_env("DATABASE_URL") ||
          raise "DATABASE_URL is required when DB_ADAPTER=postgres"

      config :coordinator, Coordinator.Repo,
        url: database_url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
        ssl: System.get_env("DATABASE_SSL") == "true"

      # Basic engine + Postgres LISTEN/NOTIFY notifier for a real RDBMS.
      config :coordinator, Oban,
        engine: Oban.Engines.Basic,
        notifier: Oban.Notifiers.Postgres,
        repo: Coordinator.Repo,
        queues: [leases: 10]

    _sqlite ->
      config :coordinator, Coordinator.Repo,
        database: System.get_env("DATABASE_PATH") || "/var/lib/hydra/coordinator.db",
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

      # Lite engine + PG (process-group) notifier for SQLite.
      config :coordinator, Oban,
        engine: Oban.Engines.Lite,
        notifier: Oban.Notifiers.PG,
        repo: Coordinator.Repo,
        queues: [leases: 10]
  end

  if secret = System.get_env("SECRET_KEY_BASE") do
    config :coordinator, Coordinator.Endpoint, secret_key_base: secret
  end
end
