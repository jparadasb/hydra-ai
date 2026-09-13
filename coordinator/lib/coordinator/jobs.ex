defmodule Coordinator.Jobs do
  @moduledoc """
  Durable job + lease lifecycle. Jobs are persisted, then an Oban job (`Coordinator.LeaseWorker`)
  assigns each to an eligible worker via `Coordinator.Router`. Leasing survives restarts; a job
  that no worker can take yet is retried (snoozed) until one appears.

  States: `pending` → `leased` → `done` | `failed` | `cancelled`. A non-OK result re-queues the job (up to
  `@max_attempts`) so it can be retried on another worker.

  Every row carries a second, finer `state` (see `Coordinator.Jobs.State`) describing where
  inside its `status` the job actually is — what a delegating agent polls for. `status` stays
  the five-value column that every compare-and-swap here guards on, because widening it would
  turn each of those guards into an N-value list that has to stay in sync.

  The discipline that keeps the pair honest: **every `set:` that writes `status` writes `state`
  in the same list.** `update_all` bypasses changesets by design, so nothing validates it at
  write time; `jobs_state_test.exs` walks every write path in this module and asserts the pair.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Coordinator.{Job, Repo}
  alias Coordinator.Jobs.{JobRecord, State}

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
          # A repeated idempotent submission lands here and is not a failure: `submit/1` turns
          # it into the existing job. Logging it as an error would make a working retry look
          # like an incident.
          if match?(%Ecto.Changeset{}, reason) and idempotency_conflict?(reason) do
            Logger.debug("job #{id} already submitted under this idempotency key")
          else
            Logger.error("job #{id} could not be enqueued: #{inspect(reason)}")
          end

          Repo.rollback(reason)
      end
    end)
  end

  defp enqueue_lease(job_id, schedule_in_seconds \\ 0) do
    opts = if schedule_in_seconds > 0, do: [schedule_in: schedule_in_seconds], else: []
    %{job_id: job_id} |> Coordinator.LeaseWorker.new(opts) |> Oban.insert()
  end

  @doc """
  Submit a job on behalf of a caller, returning the existing one if they have submitted it
  before.

  Wraps `enqueue/1` rather than changing it: an agent that retries after a dropped connection
  must not buy a second run of an expensive job, but nothing else needs that ceremony and the
  existing callers keep their two-element return.

  Idempotency is scoped to `owner_scope`, so two callers can use the same key without colliding.
  A repeat returns the first job whatever state it is in — queued, running, or long finished —
  and the payloads are not compared: a key reused with different content returns the first job,
  which is what the tool description tells callers.
  """
  def submit(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case enqueue(attrs) do
      {:ok, record} ->
        {:ok, :created, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Postgres aborts a transaction on a failed statement, so the losing writer cannot read
        # inside it — `enqueue/1` has already rolled back by the time we get here. Harmless on
        # SQLite; written for the adapter that cares.
        if idempotency_conflict?(changeset) do
          existing(attrs)
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp idempotency_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:owner_scope, {_, opts}} -> opts[:constraint] == :unique
      {:idempotency_key, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp existing(attrs, retries \\ 1) do
    scope = attrs["owner_scope"]
    key = attrs["idempotency_key"]

    case Repo.get_by(JobRecord, owner_scope: scope, idempotency_key: key) do
      %JobRecord{} = record ->
        {:ok, :existing, record}

      nil when retries > 0 ->
        # The winner's transaction has not committed yet. Rare, and only between two racing
        # submissions of the same key.
        Process.sleep(25)
        existing(attrs, retries - 1)

      nil ->
        {:error, :idempotency_conflict}
    end
  end

  def get(id), do: Repo.get(JobRecord, id)

  @doc """
  Fetch a job only if this caller owns it.

  A job id used to be known only to whoever submitted it, so `get/1` needed no check. MCP hands
  ids to agents, which makes an id a thing that can be guessed, shared or logged — so every
  caller-facing read goes through here.

  A job owned by someone else returns `nil`, exactly like one that does not exist. Telling the
  two apart would let a caller probe which ids are real.
  """
  def get_for_caller(id, owner_scope) when is_binary(id) and is_binary(owner_scope) do
    case get(id) do
      %JobRecord{owner_scope: ^owner_scope} = record -> record
      _ -> nil
    end
  end

  def get_for_caller(_, _), do: nil

  @doc """
  How many jobs this caller has in flight.

  A blocking HTTP request was its own backpressure: a caller could only have as many jobs as it
  was willing to hold connections open for. Submitting asynchronously removes that, so the
  ceiling has to be explicit.
  """
  def open_job_count(owner_scope) when is_binary(owner_scope) do
    from(j in JobRecord,
      where: j.owner_scope == ^owner_scope and j.status in ["pending", "leased"],
      select: count(j.id)
    )
    |> Repo.one()
  end

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
          state: "leased",
          # When the job actually went out. `updated_at` cannot answer this: `renew_lease/3`
          # rewrites it every 20s, so the turnaround it used to measure was really "time since
          # the last heartbeat".
          leased_at: now(),
          # A previous attempt's progress describes a generation that no longer owns this job.
          progress_seq: nil,
          started_at: nil,
          last_progress_at: nil,
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

  @doc """
  Note that this job is being routed right now.

  Observational only — it does not change `status`, so nothing about leasing depends on it. The
  guard matters for a different reason: `Coordinator.LeaseWorker` snoozes every five seconds for
  up to twenty attempts while no worker is eligible, so an unguarded write here would be its own
  slow write storm. Conditioning on `state == "queued"` makes it one UPDATE per job.
  """
  def mark_routing(%JobRecord{} = record) do
    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status == "pending" and j.state == "queued"
      )
      |> Repo.update_all(set: [state: "routing"])

    if count == 1, do: :ok, else: :noop
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
          state: "expired",
          result: %{"status" => "error", "reason" => "deadline_expired"},
          failure_reason: "deadline_expired",
          finished_at: now(),
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
          state: "failed",
          worker_id: nil,
          lease_id: nil,
          lease_expires_at: nil,
          result: %{"status" => "error", "reason" => "lease_expired"},
          failure_reason: "lease_expired",
          finished_at: now(),
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
  Record how far a running job has got.

  One statement, and deliberately narrow. Three guards decide whether it writes at all:

    * `status == "leased"` — a job that finished, was cancelled or was requeued is no longer
      accepting progress;
    * `lease_id` matches — a superseded generation must not overwrite the live one's counts;
    * `seq` advances — a replayed or reordered frame is dropped rather than rewinding the count.

  A frame that fails any of them affects zero rows and is silently ignored, which is what makes
  the message safe to fire and forget from the worker.

  **It does not touch `updated_at`.** `Coordinator.JobRetention` and `Coordinator.Stats` both
  read that column as "when the job finished"; bumping it here would push a long job's redaction
  window out for as long as it keeps talking, and skew the throughput chart. It does not renew
  the lease either — `renew_lease/3` is the explicit heartbeat, and conflating the two would
  make "the worker is alive" and "the worker is making progress" indistinguishable.
  """
  def record_progress(job_id, %{} = progress) when is_binary(job_id) do
    lease_id = progress["lease_id"]
    seq = progress["seq"]

    if is_binary(lease_id) and is_integer(seq) and seq >= 0 do
      now = now()

      {count, _} =
        from(j in JobRecord,
          where:
            j.id == ^job_id and j.status == "leased" and j.lease_id == ^lease_id and
              (is_nil(j.progress_seq) or j.progress_seq < ^seq)
        )
        |> Repo.update_all(set: progress_set(progress, seq, now))

      if count == 1, do: :ok, else: {:error, :stale_progress}
    else
      {:error, :invalid_progress}
    end
  end

  # `started_at` is written on the first frame of a lease generation only. The `is_nil(seq)`
  # guard in the query above makes that exactly once per generation without needing a COALESCE
  # fragment that would have to be written twice for the two adapters.
  defp progress_set(progress, seq, now) do
    base = [progress_seq: seq, last_progress_at: now]

    base = if seq == 0, do: Keyword.put(base, :started_at, now), else: base

    base
    |> put_state(progress["phase"])
    |> put_present(:input_tokens, progress["input_tokens"])
    |> put_present(:output_tokens, progress["output_tokens"])
    |> put_present(:actual_model, progress["model"])
    |> put_present(:provider, progress["provider"])
  end

  defp put_state(set, phase) when phase in ~w(loading_model prefill generating finalizing),
    do: Keyword.put(set, :state, phase)

  defp put_state(set, _), do: set

  # A field the backend did not report must not overwrite one it reported earlier: absent means
  # "no measurement", which is not the same as zero.
  defp put_present(set, _key, nil), do: set
  defp put_present(set, key, value), do: Keyword.put(set, key, value)

  @doc """
  What a caller polling this job should be told: timings and throughput, computed rather than
  stored.

  Tokens-per-second is derived here on purpose. Storing it would mean a column that goes stale
  the moment the worker pauses, and it would break the standing rule that a worker may say what
  it produced but not how fast it is — throughput is the coordinator's measurement.
  """
  def progress_view(%JobRecord{} = r) do
    elapsed_ms = span_ms(r.started_at, r.last_progress_at || r.finished_at)

    %{
      state: r.state,
      status: r.status,
      worker_id: r.worker_id,
      requested_model: r.payload["model"],
      actual_model: r.actual_model,
      provider: r.provider,
      attempts: r.attempts,
      failure_reason: r.failure_reason,
      input_tokens: r.input_tokens,
      output_tokens: r.output_tokens,
      queue_seconds: seconds(span_ms(r.inserted_at, r.leased_at || r.finished_at)),
      elapsed_seconds: seconds(elapsed_ms),
      tokens_per_second: throughput(r.output_tokens, elapsed_ms),
      last_progress_at: r.last_progress_at
    }
  end

  def progress_view(nil), do: nil

  defp span_ms(%DateTime{} = from, %DateTime{} = to),
    do: max(DateTime.diff(to, from, :millisecond), 0)

  defp span_ms(_, _), do: nil

  defp seconds(nil), do: nil
  defp seconds(ms), do: Float.round(ms / 1000, 1)

  # Needs both a count and a span to mean anything. A job that has reported once has no span
  # yet, and dividing by it would report an infinite rate on its first frame.
  defp throughput(tokens, ms) when is_integer(tokens) and is_integer(ms) and ms > 0 do
    Float.round(tokens * 1000 / ms, 2)
  end

  defp throughput(_, _), do: nil

  @doc """
  PubSub topic carrying one job's progress. Per-job, like results and chunks.
  """
  def progress_topic(job_id) when is_binary(job_id), do: "job_progress:" <> job_id

  @doc """
  Record a worker's result. `ok` → done. Otherwise re-queue for another attempt until
  `@max_attempts`, then mark failed.
  """
  def complete(job_id, %{} = result) do
    case get(job_id) do
      nil ->
        {:error, :unknown_job}

      # The worker finished, or died trying, after the job was already cancelled. Its output is
      # not the job's answer — the caller asked for it to stop, and a later reader must not be
      # handed a completion for a cancelled job. But what it measured is real and is the last
      # word on how far the job actually got, so the counts are kept and the result is not.
      %{status: "cancelled"} = record ->
        {:ok, record} = record_final_usage(record, result)
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

  # Fold a worker's reported usage onto a job whose outcome is already decided. Never touches
  # `status`, `state` or `result`.
  defp record_final_usage(record, result) do
    usage = result["usage"] || %{}

    set =
      []
      |> put_present(:input_tokens, usage["input_tokens"])
      |> put_present(:output_tokens, usage["output_tokens"])
      |> put_present(:actual_model, usage["model"])
      |> put_present(:provider, usage["provider"])

    if set == [] do
      {:ok, record}
    else
      from(j in JobRecord, where: j.id == ^record.id) |> Repo.update_all(set: set)
      {:ok, get(record.id)}
    end
  end

  defp apply_result(record, result) do
    status = result["status"]

    cond do
      status == "ok" ->
        # The worker's own counts are the authoritative ones — progress reports were a live
        # approximation, and a job that never streamed has none at all. Fold them onto the row
        # before it goes terminal, so a caller reading the finished job sees real usage.
        {:ok, record} = record_final_usage(record, result)
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

  @doc """
  Cancel a pending or leased job, and tell its worker to stop.

  Returns which of the two things happened, because a caller needs to know: `:cancelled` means
  this call stopped it, `:already_terminal` means it had finished, failed or been cancelled
  before the request arrived. Both are successes — cancelling twice is not an error — but an
  agent that asked to stop a job wants to hear that it stopped something rather than nothing.

  Signalling the worker happens here rather than at the call site. It used to live in the HTTP
  router, which meant every new caller had to remember to do it; `reclaim_lease/1` already
  cancels from inside this module, so this is the consistent home for it.

  The order matters and is the same as before: persist first, then notify. A late result from a
  worker that had already started responding cannot then resurrect or requeue the job, because
  `complete/2` sees a cancelled row.

  Partial metrics survive. Only `result` is overwritten, so the token counts, the model that
  actually ran and the timings stay on the row — which is the whole point of cancelling a job
  you have been watching.
  """
  def cancel(job_id) do
    case get(job_id) do
      nil ->
        {:error, :unknown_job}

      %{status: status} = record when status in ["pending", "leased"] ->
        {:ok, cancelled} =
          update_status(
            record,
            "cancelled",
            %{"status" => "cancelled", "reason" => "cancelled_by_client"},
            "cancelled"
          )

        # A pending job has no worker to tell. A leased one does, and it is holding a slot.
        if is_binary(record.worker_id) and is_binary(record.lease_id) do
          Coordinator.WorkerChannel.cancel(record.worker_id, record.id, record.lease_id)
        end

        {:ok, :cancelled, cancelled}

      record ->
        {:ok, :already_terminal, record}
    end
  end

  defp update_status(record, status, result, state \\ nil) do
    state = state || List.first(State.states_for(status))
    finished = now()

    {count, _} =
      from(j in JobRecord,
        where: j.id == ^record.id and j.status in ["pending", "leased"]
      )
      |> Repo.update_all(
        set: [
          status: status,
          state: state,
          result: result,
          finished_at: finished,
          failure_reason: failure_reason(status, result),
          updated_at: finished
        ]
      )

    if count == 1 do
      Coordinator.Telemetry.emit([:hydra, :job, :completed], %{count: 1}, %{status: status})

      Logger.info("job #{status}",
        job_id: record.id,
        worker_id: record.worker_id,
        attempts: record.attempts,
        reason: result["reason"]
      )

      # Lease to terminal result — the worker's turnaround, not the caller's total wait. This
      # used to measure from `updated_at`, which `renew_lease/3` rewrites every 20s, so on any
      # job that outlived one heartbeat it was really reporting "time since the last heartbeat".
      # `leased_at` is written once, when the job actually goes out.
      if record.status == "leased" and match?(%DateTime{}, record.leased_at) do
        Coordinator.Telemetry.emit(
          [:hydra, :job, :duration],
          %{millisecond: DateTime.diff(finished, record.leased_at, :millisecond)}
        )
      end
    end

    {:ok, get(record.id)}
  end

  # A short code for the row, so "why did this fail" is answerable without parsing the result
  # map — and so it survives redaction, which drops everything caller-shaped.
  defp failure_reason("done", _result), do: nil

  defp failure_reason(_status, %{"reason" => reason}) when is_binary(reason) do
    String.slice(reason, 0, 255)
  end

  defp failure_reason(_status, _result), do: nil

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
          state: State.initial(),
          worker_id: nil,
          lease_id: nil,
          lease_expires_at: nil,
          leased_at: nil,
          # Per-attempt measurements describe the attempt that just failed, not the job. The
          # prompt is the exception: it does not change between attempts, so `input_tokens`
          # stays. `attempts` already records that an attempt happened.
          progress_seq: nil,
          started_at: nil,
          last_progress_at: nil,
          output_tokens: nil,
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
