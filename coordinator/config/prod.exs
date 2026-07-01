import Config

config :coordinator, Coordinator.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
  server: true

# The /admin console requires GitHub-OAuth login in prod. (Open on loopback dev.) Can be
# disabled at boot with HYDRA_ADMIN_AUTH=false — see config/runtime.exs.
config :coordinator, :admin_auth_required, true

# secret_key_base MUST be provided via env in production:
#   config :coordinator, Coordinator.Endpoint, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

# Repo connection + Oban engine are configured at runtime (config/runtime.exs), branching on
# DB_ADAPTER (sqlite3 | postgres).

config :logger, level: :info
