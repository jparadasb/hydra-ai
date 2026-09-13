import Config

# server: true so the integration test can drive the real worker binary over a TCP socket.
# In-process ChannelTest still works regardless.
config :coordinator, Coordinator.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  server: true

# Plain pool (not the SQL sandbox): channel/worker processes touch the repo cross-process,
# so a shared connection is simpler. DB-touching tests run async: false and clean up.
#
# The suite runs against whichever adapter the build was compiled for. It is SQLite by default
# (no server needed) and Postgres in CI's `test-postgres` job — production runs Postgres, and
# until that job existed the adapter serving users was compile-verified and nothing more.
if System.get_env("DB_ADAPTER") in ["postgres", "postgresql"] do
  config :coordinator, Coordinator.Repo,
    url:
      System.get_env("COORDINATOR_TEST_DATABASE_URL") ||
        "ecto://postgres:postgres@localhost:5432/coordinator_test",
    pool_size: 5

  # Postgres has LISTEN/NOTIFY, so Oban uses its own notifier and the Basic engine here too —
  # otherwise the test run would exercise a combination no deployment uses.
  config :coordinator, Oban,
    engine: Oban.Engines.Basic,
    notifier: Oban.Notifiers.Postgres,
    repo: Coordinator.Repo,
    testing: :manual
else
  config :coordinator, Coordinator.Repo,
    database:
      System.get_env("COORDINATOR_TEST_DATABASE") ||
        Path.expand("../coordinator_test.db", __DIR__),
    pool_size: 1,
    journal_mode: :wal,
    busy_timeout: 5000

  # Oban runs inline-manually in tests; assert via Oban.Testing / perform_job.
  config :coordinator, Oban, testing: :manual
end

config :logger, level: :warning

# Front-door limits off by default in tests: the suite drives many requests from one identity
# (loopback) and each test that cares about a limit sets its own.
config :coordinator,
  rate_limit_per_minute: 0,
  max_concurrent_per_key: 0
