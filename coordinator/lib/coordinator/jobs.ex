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

  def mark_leased(%JobRecord{} = r, worker_id, lease_id, renewable? \\ false) do
    {count, _} =
      from(j in JobRecord, where: j.id == ^r.id and j.status == "pending")
      |> Repo.update_all(
        set: [
          status: "leased",
          worker_id: worker_id,
          lease_id: lease_id,
          lease_expires_at: lease_deadline(r, renewable?),
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
    |> Enum.reduce(:ok, fn record, result ->
      merge_reclaim_result(result, reclaim_lease(record))
    end)
  end

  @doc "Reclaim all active leases when a worker's final channel disconnects."
  def reclaim_worker_leases(worker_id) when is_binary(worker_id) do
    from(j in JobRecord, where: j.status == "leased" and j.worker_id == ^worker_id)
    |> Repo.all()
    |> Enum.reduce(:ok, fn record, result ->
      merge_reclaim_result(result, reclaim_lease(record))
    end)
  end

  @doc "Renew one lease generation without extending it past the caller deadline."
  def renew_lease(worker_id, job_id, lease_id)
      when is_binary(worker_id) and is_binary(job_id) and is_binary(lease_id) do
    case get(job_id) do
      %JobRecord{} = record ->
        {count, _} =
          from(j in JobRecord,
            where:
              j.id == ^job_id and j.status == "leased" and j.worker_id == ^worker_id and
                j.lease_id == ^lease_id
          )
          |> Repo.update_all(
            set: [lease_expires_at: lease_deadline(record, true), updated_at: now()]
          )

        if count == 1, do: :ok, else: {:error, :stale_lease}

      nil ->
        {:error, :unknown_job}
    end
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
      Coordinator.WorkerChannel.cancel(record.worker_id, record.id, record.lease_id)
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

    case result do
      # Cancel only once the reclaim is durable. Inside the transaction, a rollback would
      # leave the row `leased` to a worker that has already aborted the inference.
      {:ok, :reclaimed} ->
        Coordinator.WorkerChannel.cancel(record.worker_id, record.id, record.lease_id)
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        :ok
    end
  end

  defp merge_reclaim_result(:ok, next), do: next
  defp merge_reclaim_result({:error, _} = error, _next), do: error

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
        # A result stamped with a superseded generation must not decide the job: its lease
        # was already reclaimed and re-leased, and another worker is live on it.
        if is_binary(result["lease_id"]) and result["lease_id"] != record.lease_id do
          {:error, :stale_lease}
        else
          apply_result(record, result)
        end
    end
  end

  defp apply_result(record, result) do
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

  defp lease_deadline(%JobRecord{} = record, true) do
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

  # A job with no caller deadline still needs a lease deadline: `reclaim_expired_leases`
  # compares `lease_expires_at <= now`, and SQL never matches NULL, so a NULL deadline would
  # strand the job in `leased` forever.
  defp lease_deadline(%JobRecord{} = record, false) do
    case Map.get(record, :expires_at) do
      %DateTime{} = expires_at -> expires_at
      _ -> deadline(lease_timeout_ms())
    end
  end

  defp broadcast_result(result) do
    Phoenix.PubSub.broadcast(Coordinator.PubSub, "job_results", {:job_result, result})
  end

  defp deadline(milliseconds), do: DateTime.add(now(), milliseconds, :millisecond)
  defp now, do: DateTime.utc_now()
end
