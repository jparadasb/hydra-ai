import Config

config :coordinator, Coordinator.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
  server: true

# secret_key_base MUST be provided via env in production:
#   config :coordinator, Coordinator.Endpoint, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

config :coordinator, Coordinator.Repo,
  database: System.get_env("DATABASE_PATH") || "/var/lib/hydra/coordinator.db",
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

config :logger, level: :info
