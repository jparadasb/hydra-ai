defmodule Coordinator.Repo do
  @moduledoc """
  Ecto repo (SQLite). Persists jobs/leases and backs Oban (Lite engine) so leasing survives
  restarts. SQLite keeps the coordinator self-contained — no separate DB server to run.
  """
  use Ecto.Repo,
    otp_app: :coordinator,
    adapter: Ecto.Adapters.SQLite3
end
