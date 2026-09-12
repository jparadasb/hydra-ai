defmodule Coordinator.Jobs do
  @moduledoc """
  Durable job + lease lifecycle. Jobs are persisted, then an Oban job (`Coordinator.LeaseWorker`)
  assigns each to an eligible worker via `Coordinator.Router`. Leasing survives restarts; a job
  that no worker can take yet is retried (snoozed) until one appears.

  States: `pending` → `leased` → `done` | `failed` | `cancelled`. A non-OK result re-queues the job (up to
  `@max_attempts`) so it can be retried on another worker.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Coordinator.{Job, Repo}
  alias Coordinator.Jobs.JobRecord

  @max_attempts 5
  @retry_backoff_base_seconds 2
  @retry_backoff_max_seconds 60
  @default_job_timeout_ms 300_000
  @default_lease_timeout_ms 60_000

  @doc """
  Persist a new job and enqueue its lease assignment.

  Both writes happen in one transaction. Separately, a failed `Oban.insert` left a `pending`
  row that nothing would ever pick up — a job silently lost, visible only by reading the table.
  """
  def enqueue(attrs) do
    id = attrs[:id] || attrs["id"] || gen_id()

    record_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("id", id)
      |> Map.put_new("status", "pending")
      |> Map.put_new("expires_at", deadline(@default_job_timeout_ms))

    Repo.transaction(fn ->
      with {:ok, record} <- %JobRecord{} |> JobRecord.changeset(record_attrs) |> Repo.insert(),
           {:ok, _oban} <- enqueue_lease(id) do
        Coordinator.Telemetry.emit([:hydra, :job, :enqueued], %{count: 1})
        Logger.info("job enqueued", job_id: id, capability: record.capability)
        record
      else
        {:error, reason} ->
          Logger.error("job #{id} could not be enqueued: #{inspect(reason)}")
          Repo.rollback(reason)
      end
    end)
  end

  defp enqueue_lease(job_id, schedule_in_seconds \\ 0) do
    opts = if schedule_in_seconds > 0, do: [schedule_in: schedule_in_seconds], else: []
    %{job_id: job_id} |> Coordinator.LeaseWorker.new(opts) |> Oban.insert()
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

  @doc """
  Take a pending job for `worker_id` under a fresh lease generation.

  Conditional on the row still being `pending`, so two nodes racing to lease the same job
  cannot both win; the loser gets `{:error, :not_pending}` and does nothing.

  This does **not** touch `attempts`. That counter bounds *failures* (see `requeue/1` and
  lease reclamation) — counting successful handoffs here meant a job that failed five times
  without ever being re-leased never spent a single attempt.
  """
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
        ]
      )

    if count == 1 do
      Coordinator.Telemetry.emit([:hydra, :job, :leased], %{count: 1})
      Logger.info("job leased", job_id: r.id, worker_id: worker_id, lease_id: lease_id)
      {:ok, get(r.id)}
    else
      # Another node won the race for this job; it is already running somewhere.
      Logger.debug("lease lost", job_id: r.id, worker_id: worker_id)
      {:error, :not_pending}
    end
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
      Coordinator.Telemetry.emit([:hydra, :lease, :reclaimed], %{count: 1}, %{outcome: "failed"})

      # The abandoned-worker signal: a lease ran out with no result and the job has no budget
      # left. This is what a wedged worker looks like from here.
      Logger.warning("job failed after lease expiry",
        job_id: record.id,
        worker_id: record.worker_id,
        attempts: record.attempts
      )

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
          # A lease that ran out is a failed attempt, and is counted as one — this is half of
          # what `@max_attempts` is supposed to bound.
          |> Repo.update_all(
            set: [
              status: "pending",
              worker_id: nil,
              lease_id: nil,
              lease_expires_at: nil,
              updated_at: now()
            ],
            inc: [attempts: 1]
          )

        if count == 1 do
          Coordinator.Telemetry.emit(
            [:hydra, :lease, :reclaimed],
            %{count: 1},
            %{outcome: "requeued"}
          )

          Logger.warning("lease reclaimed and job requeued",
            job_id: record.id,
            worker_id: record.worker_id,
            lease_id: record.lease_id,
            attempts: record.attempts + 1
          )

          case enqueue_lease(record.id, retry_delay(record.attempts + 1)) do
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
        Logger.warning(
          "job #{record.id} failed after #{record.attempts} attempts: #{inspect(result["reason"])}"
        )

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
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status in ["pending", "leased"]
      )
      |> Repo.update_all(set: [status: status, result: result, updated_at: now()])

    if count == 1 do
      Coordinator.Telemetry.emit([:hydra, :job, :completed], %{count: 1}, %{status: status})

      Logger.info("job #{status}",
        job_id: record.id,
        worker_id: record.worker_id,
        attempts: record.attempts,
        reason: result["reason"]
      )

      # Lease to terminal result. `updated_at` was last written when the job was leased, so
      # this is the worker's turnaround rather than the caller's total wait.
      if record.status == "leased" and match?(%DateTime{}, record.updated_at) do
        Coordinator.Telemetry.emit(
          [:hydra, :job, :duration],
          %{millisecond: DateTime.diff(now(), record.updated_at, :millisecond)}
        )
      end
    end

    {:ok, get(record.id)}
  end

  @doc """
  Reset a job to pending and re-enqueue its lease assignment after a failed attempt.

  Spends one attempt and delays the retry. Without the delay, a worker that errors
  deterministically on a job burned the whole retry budget in a fraction of a second.
  """
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
        ],
        inc: [attempts: 1]
      )

    if count == 1 do
      requeue_lease(record.id)
    else
      {:ok, get(record.id)}
    end
  end

  # Re-enqueue after an attempt was spent, backing off on the count the database now holds
  # (not on a possibly stale in-memory snapshot).
  defp requeue_lease(job_id) do
    record = get(job_id)
    delay = retry_delay(record.attempts)
    Coordinator.Telemetry.emit([:hydra, :job, :requeued], %{count: 1})

    Logger.info("job requeued",
      job_id: job_id,
      attempt: record.attempts,
      max_attempts: @max_attempts,
      retry_in_seconds: delay
    )

    with {:ok, _} <- enqueue_lease(job_id, delay), do: {:ok, record}
  end

  # Exponential, capped: 2s, 4s, 8s, 16s, 32s, then 60s.
  defp retry_delay(attempts) when is_integer(attempts) and attempts > 0 do
    min(
      @retry_backoff_base_seconds * Integer.pow(2, min(attempts - 1, 16)),
      @retry_backoff_max_seconds
    )
  end

  defp retry_delay(_), do: @retry_backoff_base_seconds

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

  @doc """
  PubSub topic carrying one job's terminal result. Per-job (mirroring `"job_chunks:<job_id>"`)
  so a waiting caller's process only ever receives its own completion: a shared topic copies
  every completion to every in-flight request and puts other callers' output in its mailbox.
  """
  def result_topic(job_id) when is_binary(job_id), do: "job_results:" <> job_id

  defp broadcast_result(%{"job_id" => job_id} = result) do
    Phoenix.PubSub.broadcast(Coordinator.PubSub, result_topic(job_id), {:job_result, result})
  end

  defp deadline(milliseconds), do: DateTime.add(now(), milliseconds, :millisecond)
  defp now, do: DateTime.utc_now()
end
