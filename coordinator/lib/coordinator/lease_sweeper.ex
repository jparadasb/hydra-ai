defmodule Coordinator.LeaseSweeper do
  @moduledoc "Reclaims durable leases whose workers did not complete before their deadline."
  use Oban.Worker, queue: :leases, max_attempts: 3, unique: [period: 50]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Coordinator.Jobs.reclaim_expired_leases()
  end
end
