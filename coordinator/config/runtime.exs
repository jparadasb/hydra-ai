import Config

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
