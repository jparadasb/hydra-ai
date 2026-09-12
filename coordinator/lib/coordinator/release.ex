defmodule Coordinator.Release do
  @moduledoc """
  Release tasks (migrations) for production deploys, where Mix is unavailable.

      bin/coordinator eval "Coordinator.Release.migrate()"

  Works for whichever backend the release was built against (`DB_ADAPTER`).

  **Concurrent replicas.** `entrypoint.sh` runs this on every pod start, so N replicas can
  race. On Postgres they do not collide: `Ecto.Migrator` takes its migration lock
  (`:migration_lock`, `:table_lock` by default) on `schema_migrations`, so the second migrator
  blocks and then finds nothing left to run. On SQLite the question does not arise —
  `Coordinator.BootCheck` refuses to start a clustered SQLite deployment, so there is only ever
  one pod holding that file.
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
