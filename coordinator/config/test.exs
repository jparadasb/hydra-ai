import Config

# server: true so the integration test can drive the real worker binary over a TCP socket.
# In-process ChannelTest still works regardless.
config :coordinator, Coordinator.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  server: true

config :logger, level: :warning
