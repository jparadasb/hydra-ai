import Config

config :coordinator, Coordinator.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [], layout: false],
  pubsub_server: Coordinator.PubSub,
  # Channels carry no secrets and no signed-session state, but the endpoint still needs a
  # key base. Overridden via env in prod.
  secret_key_base: String.duplicate("hydra-dev-secret-key-base-not-for-prod", 2)

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
