import Config

config :coordinator, Coordinator.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [], layout: false],
  pubsub_server: Coordinator.PubSub,
  # LiveView (Oban dashboard under /admin) signing salt. Not a secret on its own; the endpoint
  # secret_key_base (overridden via env in prod) is what actually signs the session.
  live_view: [signing_salt: "hydra-liveview-salt"],
  # Channels carry no secrets and no signed-session state, but the endpoint still needs a
  # key base. Overridden via env in prod.
  secret_key_base: String.duplicate("hydra-dev-secret-key-base-not-for-prod", 2)

config :phoenix, :json_library, Jason

config :coordinator,
  ecto_repos: [Coordinator.Repo],
  # libcluster topologies. Empty = single node (dev/test). Prod sets a Kubernetes.DNS
  # topology from env in runtime.exs so the coordinator replicas cluster.
  cluster_topologies: []

config :coordinator, Oban,
  engine: Oban.Engines.Lite,
  # SQLite has no LISTEN/NOTIFY; use the process-group notifier.
  notifier: Oban.Notifiers.PG,
  repo: Coordinator.Repo,
  queues: [leases: 10]

import_config "#{config_env()}.exs"
