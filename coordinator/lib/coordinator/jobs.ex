defmodule Coordinator.Jobs do
  @moduledoc """
  Durable job + lease lifecycle. Jobs are persisted, then an Oban job (`Coordinator.LeaseWorker`)
  assigns each to an eligible worker via `Coordinator.Router`. Leasing survives restarts; a job
  that no worker can take yet is retried (snoozed) until one appears.

  States: `pending` → `leased` → `done` | `failed`. A non-OK result re-queues the job (up to
  `@max_attempts`) so it can be retried on another worker.
  """

  import Ecto.Query, warn: false

  alias Coordinator.{Job, Repo}
  alias Coordinator.Jobs.JobRecord

  @max_attempts 5

  @doc "Persist a new job and enqueue its lease assignment."
  def enqueue(attrs) do
    id = attrs[:id] || attrs["id"] || gen_id()

    record_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("id", id)
      |> Map.put_new("status", "pending")

    with {:ok, record} <- %JobRecord{} |> JobRecord.changeset(record_attrs) |> Repo.insert(),
         {:ok, _oban} <- enqueue_lease(id) do
      {:ok, record}
    end
  end

  defp enqueue_lease(job_id) do
    %{job_id: job_id} |> Coordinator.LeaseWorker.new() |> Oban.insert()
  end

  def get(id), do: Repo.get(JobRecord, id)

  @doc "Build the routing-domain `Coordinator.Job` from a persisted record."
  def to_domain(%JobRecord{} = r) do
    %Job{
      job_id: r.id,
      capability: r.capability,
      privacy: Job.parse_privacy(r.privacy),
      allow_external_providers: r.allow_external_providers,
      model: r.payload["model"],
      payload: r.payload
    }
  end

  @doc "The map sent to the worker over the channel (mirrors /proto/job.schema.json)."
  def to_lease_payload(%JobRecord{} = r) do
    %{
      "job_id" => r.id,
      "lease_id" => r.lease_id,
      "capability" => r.capability,
      "privacy" => r.privacy,
      "allow_external_providers" => r.allow_external_providers,
      "payload" => r.payload
    }
  end

  def mark_leased(%JobRecord{} = r, worker_id, lease_id) do
    r
    |> JobRecord.changeset(%{
      "status" => "leased",
      "worker_id" => worker_id,
      "lease_id" => lease_id,
      "attempts" => r.attempts + 1
    })
    |> Repo.update()
  end

  @doc """
  Record a worker's result. `ok` → done. Otherwise re-queue for another attempt until
  `@max_attempts`, then mark failed.
  """
  def complete(job_id, %{} = result) do
    case get(job_id) do
      nil ->
        {:error, :unknown_job}

      record ->
        status = result["status"]

        cond do
          status == "ok" ->
            update_status(record, "done", result)

          record.attempts >= @max_attempts ->
            update_status(record, "failed", result)

          true ->
            with {:ok, record} <- requeue(record) do
              {:ok, record}
            end
        end
    end
  end

  defp update_status(record, status, result) do
    record
    |> JobRecord.changeset(%{"status" => status, "result" => result})
    |> Repo.update()
  end

  @doc "Reset a job to pending and re-enqueue its lease assignment."
  def requeue(%JobRecord{} = record) do
    with {:ok, record} <-
           record
           |> JobRecord.changeset(%{"status" => "pending", "worker_id" => nil, "lease_id" => nil})
           |> Repo.update(),
         {:ok, _} <- enqueue_lease(record.id) do
      {:ok, record}
    end
  end

  def gen_id, do: "job-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  def gen_lease_id,
    do: "lease-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
end
