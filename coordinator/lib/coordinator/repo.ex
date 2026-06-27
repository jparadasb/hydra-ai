defmodule Coordinator.Repo do
  @moduledoc """
  Ecto repo. Persists jobs/leases and backs Oban so leasing survives restarts.

  The adapter is selected at **compile time** from the `DB_ADAPTER` env var:

    * unset / `sqlite3` → `Ecto.Adapters.SQLite3` (dev/test; self-contained, no DB server)
    * `postgres`        → `Ecto.Adapters.Postgres` (production)

  Connection details + the matching Oban engine/notifier are set at runtime in
  `config/runtime.exs`. Build a Postgres release with `DB_ADAPTER=postgres` so this compiles
  against the right adapter, and provide `DATABASE_URL` at boot. See `README.md`.
  """

  @adapter (case System.get_env("DB_ADAPTER", "sqlite3") do
              adapter when adapter in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
              _ -> Ecto.Adapters.SQLite3
            end)

  use Ecto.Repo, otp_app: :coordinator, adapter: @adapter

  @doc "The adapter this repo was compiled against."
  def adapter, do: @adapter
end
