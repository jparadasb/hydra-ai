defmodule Coordinator.Jobs do
  @moduledoc """
  Durable job + lease lifecycle. Jobs are persisted, then an Oban job (`Coordinator.LeaseWorker`)
  assigns each to an eligible worker via `Coordinator.Router`. Leasing survives restarts; a job
  that no worker can take yet is retried (snoozed) until one appears.

  States: `pending` → `leased` → `done` | `failed` | `cancelled`. A non-OK result re-queues the job (up to
  `@max_attempts`) so it can be retried on another worker.
  """

  import Ecto.Query, warn: false

  alias Coordinator.{Job, Repo}
  alias Coordinator.Jobs.JobRecord

  @max_attempts 5
  @default_job_timeout_ms 300_000
  @default_lease_timeout_ms 300_000

  @doc "Persist a new job and enqueue its lease assignment."
  def enqueue(attrs) do
    id = attrs[:id] || attrs["id"] || gen_id()

    record_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("id", id)
      |> Map.put_new("status", "pending")
      |> Map.put_new("expires_at", deadline(@default_job_timeout_ms))

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
      "lease_expires_at" => deadline(lease_timeout_ms()),
      "attempts" => r.attempts + 1
    })
    |> Repo.update()
  end

  def expired?(%JobRecord{} = record) do
    case Map.get(record, :expires_at) do
      nil -> false
      expires_at -> DateTime.compare(expires_at, now()) != :gt
    end
  end

  @doc "Mark a pending job failed because its caller-facing deadline passed."
  def fail_expired(%JobRecord{} = record) do
    {count, _} =
      from(j in JobRecord, where: j.id == ^record.id and j.status == "pending")
      |> Repo.update_all(
        set: [status: "failed", result: %{"status" => "error", "reason" => "deadline_expired"}]
      )

    if count == 1, do: {:ok, get(record.id)}, else: {:error, :not_pending}
  end

  @doc "Reclaim every expired lease, failing jobs that exhausted their execution attempts."
  def reclaim_expired_leases do
    from(j in JobRecord,
      where: j.status == "leased" and j.lease_expires_at <= ^now()
    )
    |> Repo.all()
    |> Enum.each(&reclaim_lease/1)

    :ok
  end

  @doc "Reclaim all active leases owned by a disconnected worker."
  def reclaim_worker_leases(worker_id) when is_binary(worker_id) do
    from(j in JobRecord, where: j.status == "leased" and j.worker_id == ^worker_id)
    |> Repo.all()
    |> Enum.each(&reclaim_lease/1)

    :ok
  end

  defp reclaim_lease(%JobRecord{attempts: attempts} = record) when attempts >= @max_attempts do
    from(j in JobRecord,
      where: j.id == ^record.id and j.status == "leased" and j.lease_id == ^record.lease_id
    )
    |> Repo.update_all(
      set: [
        status: "failed",
        worker_id: nil,
        lease_id: nil,
        lease_expires_at: nil,
        result: %{"status" => "error", "reason" => "lease_expired"}
      ]
    )

    :ok
  end

  defp reclaim_lease(%JobRecord{} = record) do
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status == "leased" and j.lease_id == ^record.lease_id
      )
      |> Repo.update_all(
        set: [status: "pending", worker_id: nil, lease_id: nil, lease_expires_at: nil]
      )

    if count == 1, do: enqueue_lease(record.id)
    :ok
  end

  @doc """
  Record a worker's result. `ok` → done. Otherwise re-queue for another attempt until
  `@max_attempts`, then mark failed.
  """
  def complete(job_id, %{} = result) do
    case get(job_id) do
      nil ->
        {:error, :unknown_job}

      %{status: "cancelled"} = record ->
        {:ok, record}

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

  @doc "Cancel a pending or leased job. Completed terminal states remain unchanged."
  def cancel(job_id) do
    case get(job_id) do
      nil ->
        {:error, :unknown_job}

      %{status: status} = record when status in ["pending", "leased"] ->
        update_status(record, "cancelled", %{"status" => "cancelled"})

      record ->
        {:ok, record}
    end
  end

  defp update_status(record, status, result) do
    from(j in JobRecord,
      where: j.id == ^record.id and j.status in ["pending", "leased"]
    )
    |> Repo.update_all(set: [status: status, result: result])

    {:ok, get(record.id)}
  end

  @doc "Reset a job to pending and re-enqueue its lease assignment."
  def requeue(%JobRecord{} = record) do
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status in ["pending", "leased"]
      )
      |> Repo.update_all(
        set: [status: "pending", worker_id: nil, lease_id: nil, lease_expires_at: nil]
      )

    if count == 1 do
      with {:ok, _} <- enqueue_lease(record.id), do: {:ok, get(record.id)}
    else
      {:ok, get(record.id)}
    end
  end

  def gen_id, do: "job-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  def gen_lease_id,
    do: "lease-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  defp lease_timeout_ms,
    do: Application.get_env(:coordinator, :lease_timeout_ms, @default_lease_timeout_ms)

  defp deadline(milliseconds), do: DateTime.add(now(), milliseconds, :millisecond)
  defp now, do: DateTime.utc_now()
end
