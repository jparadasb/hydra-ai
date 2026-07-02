import Config

config :coordinator, Coordinator.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  debug_errors: true,
  server: true

config :coordinator, Coordinator.Repo,
  database: Path.expand("../coordinator_dev.db", __DIR__),
  pool_size: 5

config :logger, :console, format: "[$level] $message\n"
