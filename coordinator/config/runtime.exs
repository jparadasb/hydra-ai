import Config

# Worker join token (shared secret). Applies in every environment, resolved at boot. Unset or
# empty => the coordinator accepts any worker that reaches it (fine on loopback, NOT for a
# public tunnel). See Coordinator.JoinAuth.
case System.get_env("HYDRA_JOIN_TOKEN") do
  token when token in [nil, ""] -> :ok
  token -> config :coordinator, :join_token, token
end

# Require every worker to authenticate with an Ed25519 device key (Coordinator.DeviceAuth).
# Recommended for a public coordinator; rejects token-only / open connections.
config :coordinator, :require_device_auth, System.get_env("HYDRA_REQUIRE_DEVICE_AUTH") == "true"

# Gateway access key for the OpenAI-compatible HTTP front-door (Coordinator.ApiRouter). This is
# NOT a provider token — it only gates who may submit jobs. Unset/empty => the door is open
# (fine on loopback, NOT for a public tunnel). Callers send `Authorization: Bearer <token>`.
case System.get_env("HYDRA_API_TOKEN") do
  token when token in [nil, ""] -> :ok
  token -> config :coordinator, :api_token, token
end

# Routing capability for the front-door's chat requests. Workers run a chat completion for any
# capability they advertise, so this must match a capability the connected workers serve. Unset
# => "chat". (Current built-in adapters advertise e.g. "text.extract_json".)
case System.get_env("HYDRA_API_CAPABILITY") do
  cap when cap in [nil, ""] -> :ok
  cap -> config :coordinator, :api_capability, cap
end

# ---- Front-door limits (Coordinator.RateLimiter) ------------------------------------------

# Per-caller ceilings for the OpenAI-compatible front door, keyed by gateway key id (or by peer
# IP when the door is open). Without them one key holder can saturate the whole worker network.
# Set either to 0 to disable it. Limits are per coordinator node.
case Integer.parse(System.get_env("HYDRA_RATE_LIMIT_PER_MINUTE") || "") do
  {n, _} when n >= 0 -> config :coordinator, :rate_limit_per_minute, n
  _ -> :ok
end

case Integer.parse(System.get_env("HYDRA_MAX_CONCURRENT_PER_KEY") || "") do
  {n, _} when n >= 0 -> config :coordinator, :max_concurrent_per_key, n
  _ -> :ok
end

# Largest request body the front door accepts. The body is persisted verbatim into
# `jobs.payload`, so this is also the ceiling on a single job row.
case Integer.parse(System.get_env("HYDRA_MAX_BODY_BYTES") || "") do
  {n, _} when n > 0 -> config :coordinator, :max_body_bytes, n
  _ -> :ok
end

# Ceiling on one worker result. A result is persisted verbatim and copied to every subscriber,
# and results may carry artifacts, so this is the other half of HYDRA_MAX_BODY_BYTES: that one
# bounds what a caller can send in, this one bounds what a worker can send back.
case Integer.parse(System.get_env("HYDRA_MAX_RESULT_BYTES") || "") do
  {n, _} when n > 0 -> config :coordinator, :max_result_bytes, n
  _ -> :ok
end

# What to do when a streaming client hangs up before its job finishes. `cancel` (the default,
# and the behaviour this has always had) stops the job; `detach` leaves it running to be
# collected later with GET /v1/jobs/:id. Per-request override: `x-hydra-on-disconnect`.
case System.get_env("HYDRA_ON_CLIENT_DISCONNECT") do
  "detach" -> config :coordinator, :on_client_disconnect, :detach
  _ -> config :coordinator, :on_client_disconnect, :cancel
end

# --- MCP endpoint -----------------------------------------------------------------------------

# The agent-facing door. On by default: it is behind the same gateway key as /v1, and a
# coordinator with no MCP clients simply never receives a request on it.
config :coordinator,
       :mcp_enabled,
       System.get_env("HYDRA_MCP_ENABLED", "true") != "false"

# Browser origins permitted to reach /mcp. Empty by default, which refuses every request that
# carries an Origin at all — an agent client sends none, so this only matters if you deliberately
# want a web page to drive the coordinator. Without it, DNS rebinding lets any page a user visits
# talk to their local coordinator.
case System.get_env("HYDRA_MCP_ALLOWED_ORIGINS") do
  nil ->
    :ok

  "" ->
    :ok

  value ->
    config :coordinator,
           :mcp_allowed_origins,
           value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# How many jobs one gateway key may have queued or running at once. A blocking HTTP request was
# its own backpressure; asynchronous submission removes it, so without a ceiling one agent in a
# retry loop fills the queue for everyone else.
case Integer.parse(System.get_env("HYDRA_MCP_MAX_OPEN_JOBS_PER_KEY") || "") do
  {n, _} when n > 0 -> config :coordinator, :mcp_max_open_jobs_per_key, n
  _ -> :ok
end

# Whether to hand MCP clients native task handles. `auto` follows what the client declared;
# `never` refuses to, which is the setting for a client whose SDK advertises the tasks extension
# but whose agent loop does not actually poll — such a client would sit waiting for a tool result
# that never comes. `always` forces them on, for testing.
case System.get_env("HYDRA_MCP_TASKS_MODE") do
  "never" -> config :coordinator, :mcp_tasks_mode, :never
  "always" -> config :coordinator, :mcp_tasks_mode, :always
  _ -> config :coordinator, :mcp_tasks_mode, :auto
end

# Enforce a gateway key even when no env master (HYDRA_API_TOKEN) is set — so admin-issued keys
# from the /admin console alone can gate the front-door. Recommended on a public tunnel.
config :coordinator, :require_api_token, System.get_env("HYDRA_REQUIRE_API_TOKEN") == "true"

# ---- Job retention (Coordinator.JobRetention) ---------------------------------------------

# How long a completed job keeps the caller's prompt and the worker's completion before both
# are replaced with a size-only summary, and how long the (text-free) row survives after that.
# Token accounting in `usage_records` is not pruned, so consumption history outlives the text.
# Set either to 0 to disable that stage.
case Integer.parse(System.get_env("HYDRA_JOB_REDACT_AFTER_HOURS") || "") do
  {n, _} when n >= 0 -> config :coordinator, :job_redact_after_hours, n
  _ -> :ok
end

case Integer.parse(System.get_env("HYDRA_JOB_RETENTION_DAYS") || "") do
  {n, _} when n >= 0 -> config :coordinator, :job_retention_days, n
  _ -> :ok
end

# ---- Admin console (/admin): GitHub OAuth login + Oban dashboard --------------------------

# Override the prod default: set HYDRA_ADMIN_AUTH=false to open /admin without login (do NOT do
# this on a public tunnel). Only takes effect if explicitly "false".
if System.get_env("HYDRA_ADMIN_AUTH") == "false" do
  config :coordinator, :admin_auth_required, false
end

# GitHub OAuth app credentials for admin login (Coordinator.Web.AuthController). Register an
# OAuth app whose callback is <HYDRA_ADMIN_BASE_URL>/auth/github/callback.
case System.get_env("HYDRA_GITHUB_CLIENT_ID") do
  id when id in [nil, ""] -> :ok
  id -> config :coordinator, :github_client_id, id
end

case System.get_env("HYDRA_GITHUB_CLIENT_SECRET") do
  secret when secret in [nil, ""] -> :ok
  secret -> config :coordinator, :github_client_secret, secret
end

# Comma-separated GitHub logins allowed into /admin. Empty => nobody (fail closed).
case System.get_env("HYDRA_ADMIN_GITHUB_USERS") do
  users when users in [nil, ""] ->
    :ok

  users ->
    logins = users |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    config :coordinator, :admin_github_users, logins
end

# Public base URL of the coordinator, used to build the OAuth callback URL. Set this behind a
# tunnel/proxy (e.g. https://coordinator.example.com) so the redirect_uri matches the GitHub app.
case System.get_env("HYDRA_ADMIN_BASE_URL") do
  url when url in [nil, ""] -> :ok
  url -> config :coordinator, :admin_base_url, url
end

# BEAM clustering (libcluster). When HYDRA_CLUSTER_SERVICE names a headless k8s Service, the
# coordinator replicas discover each other via that Service's DNS and form one cluster, so
# Presence + PubSub span all replicas (the /admin dashboard sees every worker regardless of
# which pod it connected to). Unset = single node. Requires RELEASE_DISTRIBUTION=name +
# RELEASE_NODE=<basename>@<pod-ip> + a shared RELEASE_COOKIE across replicas.
case System.get_env("HYDRA_CLUSTER_SERVICE") do
  service when service in [nil, ""] ->
    :ok

  service ->
    config :coordinator, :cluster_topologies,
      hydra: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: service,
          application_name: System.get_env("HYDRA_CLUSTER_NODE_BASENAME", "coordinator"),
          polling_interval: 5_000
        ]
      ]
end

# Production database + Oban configuration, resolved at boot from the environment.
#
# DB_ADAPTER has no default here on purpose. It used to fall back to "sqlite3", which meant the
# documented multi-replica scaling path silently gave every pod its own database and its own
# Oban queue. Choosing the backend is a deployment decision, not something to inherit.
#
# It must also match the value the release was *built* with, since Coordinator.Repo's adapter
# is compiled in. `Coordinator.BootCheck` asserts that at startup.
if config_env() == :prod do
  db_adapter =
    System.get_env("DB_ADAPTER") ||
      raise """
      DB_ADAPTER must be set explicitly in production: "postgres" or "sqlite3".

      Use "postgres" for anything running more than one replica — SQLite is a file local to one
      pod, so replicas would not share jobs, leases, or Oban. It must match the DB_ADAPTER the
      release was built with.
      """

  config :coordinator, :db_adapter, db_adapter

  case db_adapter do
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

    adapter when adapter in ["sqlite", "sqlite3"] ->
      # Single node only. `Coordinator.BootCheck` refuses to start if a cluster topology is
      # also configured.
      config :coordinator, Coordinator.Repo,
        database: System.get_env("DATABASE_PATH") || "/var/lib/hydra/coordinator.db",
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

      # Lite engine + PG (process-group) notifier for SQLite.
      config :coordinator, Oban,
        engine: Oban.Engines.Lite,
        notifier: Oban.Notifiers.PG,
        repo: Coordinator.Repo,
        queues: [leases: 10]

    other ->
      raise ~s(unknown DB_ADAPTER #{inspect(other)} — expected "postgres" or "sqlite3")
  end

  if secret = System.get_env("SECRET_KEY_BASE") do
    config :coordinator, Coordinator.Endpoint, secret_key_base: secret
  end

  # Public host, used behind an ingress/proxy. Sets the endpoint URL (so generated URLs and the
  # OAuth callback default are correct) and constrains LiveView/socket origin checking to that
  # host — required for the /admin Oban dashboard's LiveView to connect through the ingress.
  if host = System.get_env("PHX_HOST") do
    config :coordinator, Coordinator.Endpoint,
      url: [host: host, scheme: "https", port: 443],
      check_origin: ["https://#{host}"]
  end
end
