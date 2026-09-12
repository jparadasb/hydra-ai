defmodule Coordinator.Repo do
  @moduledoc """
  Ecto repo. Persists jobs/leases and backs Oban so leasing survives restarts.

  The adapter is selected at **compile time** from the `DB_ADAPTER` env var:

    * unset / `sqlite3` → `Ecto.Adapters.SQLite3` (dev/test; self-contained, no DB server)
    * `postgres`        → `Ecto.Adapters.Postgres` (production)

  Connection details + the matching Oban engine/notifier are set at runtime in
  `config/runtime.exs`. Build a Postgres release with `DB_ADAPTER=postgres` so this compiles
  against the right adapter, and provide `DATABASE_URL` at boot. See `README.md`.

  Because the adapter is compiled in, `DB_ADAPTER` at boot cannot change it — it can only
  disagree with it. `Coordinator.BootCheck` turns that disagreement into a named startup error.

  **SQLite is single-node.** The database is a file on one pod's filesystem, so it cannot back
  more than one replica: each would get its own jobs, leases and Oban queue. Clustering with
  SQLite is refused at startup. Multi-replica deployments need Postgres.
  """

  @adapter (case System.get_env("DB_ADAPTER", "sqlite3") do
              adapter when adapter in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
              _ -> Ecto.Adapters.SQLite3
            end)

  use Ecto.Repo, otp_app: :coordinator, adapter: @adapter

  @doc "The adapter this repo was compiled against."
  def adapter, do: @adapter
end
