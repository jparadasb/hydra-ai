import Config

config :coordinator, Coordinator.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  server: true

config :logger, :console, format: "[$level] $message\n"
