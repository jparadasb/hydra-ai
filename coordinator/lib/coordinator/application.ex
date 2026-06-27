defmodule Coordinator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Coordinator.Repo,
      {Oban, Application.fetch_env!(:coordinator, Oban)},
      {Phoenix.PubSub, name: Coordinator.PubSub},
      # Live registry of connected workers (source of truth for the Router).
      Coordinator.WorkerRegistry,
      Coordinator.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Coordinator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
