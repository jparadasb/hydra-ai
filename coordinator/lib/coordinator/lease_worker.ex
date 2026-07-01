defmodule Coordinator.LeaseWorker do
  @moduledoc """
  Oban worker that assigns a pending job to an eligible worker.

  Routes the job against the live `Coordinator.WorkerRegistry` via `Coordinator.Router`. If a
  worker is chosen, the job is marked leased and pushed over the channel. If no worker is
  currently eligible, the job is snoozed and retried — so a job submitted before any capable
  worker connects is simply leased once one appears.
  """
  use Oban.Worker, queue: :leases, max_attempts: 20

  alias Coordinator.{Jobs, WorkerChannel, WorkerRegistry}

  @snooze_seconds 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id}}) do
    case Jobs.get(job_id) do
      nil ->
        :ok

      %{status: "pending"} = record ->
        lease(record)

      _already_handled ->
        :ok
    end
  end

  defp lease(record) do
    domain = Jobs.to_domain(record)

    # reserve/2 routes AND bumps the chosen worker's inflight atomically, so concurrent lease
    # jobs spread across workers instead of all landing on the same equally-scored node. The
    # reservation is released when the result arrives (Coordinator.WorkerSession.handle_result).
    case WorkerRegistry.reserve(domain) do
      {:ok, worker} ->
        lease_id = Jobs.gen_lease_id()
        {:ok, record} = Jobs.mark_leased(record, worker.worker_id, lease_id)
        WorkerChannel.lease(worker.worker_id, Jobs.to_lease_payload(record))
        :ok

      {:error, :no_eligible_worker} ->
        {:snooze, @snooze_seconds}
    end
  end
end
