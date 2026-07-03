defmodule Coordinator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Coordinator.Repo,
        {Oban, Application.fetch_env!(:coordinator, Oban)},
        {Phoenix.PubSub, name: Coordinator.PubSub}
      ] ++
        cluster_children() ++
        [
          # Cluster-wide connected-worker set (replaces the old in-memory GenServer); the
          # source of truth the Router routes against, shared across all coordinator nodes.
          Coordinator.Presence,
          Coordinator.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Coordinator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Connect the BEAM nodes so Presence + PubSub span all coordinator replicas. Only runs when
  # a topology is configured (prod, via HYDRA_CLUSTER_SERVICE); dev/test run a single node.
  defp cluster_children do
    case Application.get_env(:coordinator, :cluster_topologies, []) do
      [_ | _] = topologies ->
        [{Cluster.Supervisor, [topologies, [name: Coordinator.ClusterSupervisor]]}]

      _ ->
        []
    end
  end
end
