defmodule Coordinator.MixProject do
  use Mix.Project

  def project do
    [
      app: :coordinator,
      version: "0.1.0",
      elixir: "~> 1.19",
      # Declared so the licence is discoverable from the package metadata, not only from the
      # LICENSE file at the repo root.
      description: "hydra-ai coordinator: leases jobs to worker nodes and routes them.",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/jparadasb/hydra-ai"}
      ],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Coordinator.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      # Real Oban dashboard for the /admin job view (LiveView, self-served assets).
      {:oban_web, "~> 2.11"},
      # HTTP client for the GitHub OAuth token exchange + user lookup (admin login only).
      {:req, "~> 0.5"},
      # Clusters the coordinator's BEAM nodes so >1 replica shares worker presence + PubSub.
      {:libcluster, "~> 3.4"},
      # Metrics. `telemetry_metrics` defines them; the Prometheus core renders the scrape
      # endpoint without pulling in a second HTTP server.
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
