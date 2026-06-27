import Config

# server: true so the integration test can drive the real worker binary over a TCP socket.
# In-process ChannelTest still works regardless.
config :coordinator, Coordinator.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  server: true

# Plain pool (not the SQL sandbox): channel/worker processes touch the repo cross-process,
# so a shared connection is simpler. DB-touching tests run async: false and clean up.
config :coordinator, Coordinator.Repo,
  database: Path.expand("../coordinator_test.db", __DIR__),
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5000

# Oban runs inline-manually in tests; assert via Oban.Testing / perform_job.
config :coordinator, Oban, testing: :manual

config :logger, level: :warning
