defmodule Coordinator.Release do
  @moduledoc """
  Release tasks (migrations) for production deploys, where Mix is unavailable.

      bin/coordinator eval "Coordinator.Release.migrate()"

  Works for whichever backend the release was built against (`DB_ADAPTER`).
  """
  @app :coordinator

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
