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
  @default_lease_timeout_ms 60_000

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
    {count, _} =
      from(j in JobRecord, where: j.id == ^r.id and j.status == "pending")
      |> Repo.update_all(
        set: [
          status: "leased",
          worker_id: worker_id,
          lease_id: lease_id,
          lease_expires_at: lease_deadline(r),
          updated_at: now()
        ],
        inc: [attempts: 1]
      )

    if count == 1, do: {:ok, get(r.id)}, else: {:error, :not_pending}
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
        set: [
          status: "failed",
          result: %{"status" => "error", "reason" => "deadline_expired"},
          updated_at: now()
        ]
      )

    if count == 1 do
      result = %{"job_id" => record.id, "status" => "error", "reason" => "deadline_expired"}
      broadcast_result(result)
      {:ok, get(record.id)}
    else
      {:error, :not_pending}
    end
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

  @doc "Reclaim leases handed out by a specific disconnected worker channel."
  def reclaim_worker_leases(worker_id, lease_ids)
      when is_binary(worker_id) and is_list(lease_ids) do
    from(j in JobRecord,
      where: j.status == "leased" and j.worker_id == ^worker_id and j.lease_id in ^lease_ids
    )
    |> Repo.all()
    |> Enum.each(&reclaim_lease/1)

    :ok
  end

  defp reclaim_lease(%JobRecord{attempts: attempts} = record) when attempts >= @max_attempts do
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status == "leased" and j.lease_id == ^record.lease_id
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          worker_id: nil,
          lease_id: nil,
          lease_expires_at: nil,
          result: %{"status" => "error", "reason" => "lease_expired"},
          updated_at: now()
        ]
      )

    if count == 1 do
      Coordinator.WorkerChannel.cancel(record.worker_id, record.id)
      broadcast_result(%{"job_id" => record.id, "status" => "error", "reason" => "lease_expired"})
    end

    :ok
  end

  defp reclaim_lease(%JobRecord{} = record) do
    result =
      Repo.transaction(fn ->
        {count, _} =
          from(j in JobRecord,
            where: j.id == ^record.id and j.status == "leased" and j.lease_id == ^record.lease_id
          )
          |> Repo.update_all(
            set: [
              status: "pending",
              worker_id: nil,
              lease_id: nil,
              lease_expires_at: nil,
              updated_at: now()
            ]
          )

        if count == 1 do
          case enqueue_lease(record.id) do
            {:ok, _job} -> :reclaimed
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          :unchanged
        end
      end)

    if result == {:ok, :reclaimed} do
      Coordinator.WorkerChannel.cancel(record.worker_id, record.id)
    end

    case result do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
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
    |> Repo.update_all(set: [status: status, result: result, updated_at: now()])

    {:ok, get(record.id)}
  end

  @doc "Reset a job to pending and re-enqueue its lease assignment."
  def requeue(%JobRecord{} = record) do
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status in ["pending", "leased"]
      )
      |> Repo.update_all(
        set: [
          status: "pending",
          worker_id: nil,
          lease_id: nil,
          lease_expires_at: nil,
          updated_at: now()
        ]
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

  defp lease_deadline(%JobRecord{} = record) do
    lease_expires_at = deadline(lease_timeout_ms())

    case Map.get(record, :expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, lease_expires_at) == :lt,
          do: expires_at,
          else: lease_expires_at

      _ ->
        lease_expires_at
    end
  end

  defp broadcast_result(result) do
    Phoenix.PubSub.broadcast(Coordinator.PubSub, "job_results", {:job_result, result})
  end

  defp deadline(milliseconds), do: DateTime.add(now(), milliseconds, :millisecond)
  defp now, do: DateTime.utc_now()
end
