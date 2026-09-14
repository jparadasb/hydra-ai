defmodule Coordinator.WorkerSession do
  @moduledoc """
  The worker↔coordinator channel boundary, as pure functions so the contract is testable
  without a running Phoenix endpoint.

  A `WorkerChannel` (Phoenix.Channel) is a thin wrapper:

      def join("worker:" <> _id, payload, socket) do
        case Coordinator.WorkerSession.handle_register(payload, socket.transport_pid) do
          {:ok, worker} -> {:ok, assign(socket, :worker_id, worker.worker_id)}
          {:error, reason} -> {:error, %{reason: reason}}
        end
      end

      def handle_in("usage", payload, socket), do: ...WorkerSession.handle_usage(payload)...
      def handle_in("result", payload, socket), do: ...WorkerSession.handle_result(payload)...

  A registration passes through `Coordinator.SecretGuard.verify/1` first; a worker that tries
  to push a token at join is refused, never registered. Results, chunks and usage reports go
  through `Coordinator.SecretGuard.redact/1` instead: they are the caller's answer, and
  dropping one on a false positive left the caller waiting for a timeout with nothing to
  diagnose.
  """

  require Logger

  alias Coordinator.{Jobs, SecretGuard, Usage, Worker}

  @doc """
  Handle a worker's registration. Rejects any payload carrying secret-shaped data, then
  sanitizes (belt and suspenders), overrides the worker's self-declared policy with the admin
  grant, and returns the built `Coordinator.Worker` snapshot. The caller (the channel process)
  tracks it in `Coordinator.Presence`.
  """
  def handle_register(payload) do
    with :ok <- SecretGuard.verify(payload),
         :ok <- validate_registration(payload) do
      worker =
        payload
        |> SecretGuard.sanitize()
        |> apply_admin_policy()
        |> Worker.from_registration()

      {:ok, worker}
    end
  end

  # Both halves of a worker's routing policy are the admin's to set (`Coordinator.WorkerPolicies`),
  # not the worker's: whatever the registration declares is replaced.
  #
  #   * privacy levels — public-only until an admin raises it
  #   * trust level — untrusted until an admin raises it. The router pays a -20 score bonus for
  #     "trusted", so a worker naming its own trust won every routing decision against honest
  #     workers.
  defp apply_admin_policy(%{"worker_id" => worker_id} = payload) do
    levels = Coordinator.WorkerPolicies.accepted_levels(worker_id)

    payload
    |> Map.update(
      "privacy",
      %{"accepted_job_levels" => levels},
      &Map.put(&1, "accepted_job_levels", levels)
    )
    |> Map.put("trust_level", Coordinator.WorkerPolicies.trust_level(worker_id))
  end

  @doc """
  Handle an aggregated usage report. Secret-shaped values are redacted rather than rejected —
  a usage report is counters, and losing one to a false positive loses accounting for no gain.
  Returns the redacted report.
  """
  def handle_usage(payload) do
    {clean, _redactions} = SecretGuard.redact(payload)
    {:ok, clean}
  end

  @doc """
  Handle a normalized job result from a worker. Broadcasts the (sanitized, secret-free)
  result on the job's own `"job_results:<job_id>"` PubSub topic so the waiting caller (and
  schedulers/tests) observe the completion without seeing anyone else's. The worker's usage
  report is written to `usage_records` (attributed to the key that submitted the job) instead
  of being discarded.
  Secret-shaped values are redacted in place rather than costing the caller the whole result.
  A result carrying a superseded `lease_id` is rejected (`{:error, :stale_lease}`) and never
  broadcast — the job has been re-leased and a live generation owns its outcome.

  The worker's inflight count is maintained by its channel process (which sees the job go out
  and the result come back), not here — so there is no reservation to release.
  """
  def handle_result(payload) do
    case oversize(payload) do
      {:error, bytes} ->
        # Refused rather than stored. The result is persisted verbatim and copied to every
        # subscriber, so an unbounded one is the coordinator spending memory a worker chose.
        # The job still gets an outcome — silently dropping it would strand the caller.
        Logger.warning("worker result refused: too large",
          job_id: payload["job_id"],
          bytes: bytes
        )

        refusal =
          payload
          |> Map.take(["job_id", "lease_id"])
          |> Map.merge(%{"status" => "error", "reason" => "result_too_large"})

        persist_result(refusal)

        Phoenix.PubSub.broadcast(
          Coordinator.PubSub,
          Jobs.result_topic(refusal["job_id"]),
          {:job_result, refusal}
        )

        {:error, :result_too_large}

      :ok ->
        do_handle_result(payload)
    end
  end

  # Measured on the encoded payload, which is what actually costs memory downstream.
  defp oversize(payload) do
    limit = Application.get_env(:coordinator, :max_result_bytes, 1_000_000)

    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) > limit -> {:error, byte_size(encoded)}
      _ -> :ok
    end
  end

  defp do_handle_result(payload) do
    {clean, _redactions} = SecretGuard.redact(payload)

    case persist_result(clean) do
      # The result belongs to a lease generation that was already reclaimed; another
      # worker owns the job now, so this output must not reach the waiting caller.
      {:error, :stale_lease} ->
        {:error, :stale_lease}

      _ ->
        # Account before broadcasting: the caller's request process returns as soon as it
        # sees the result, and the usage row must not depend on it still being alive.
        Usage.record_result(clean)

        Phoenix.PubSub.broadcast(
          Coordinator.PubSub,
          Jobs.result_topic(clean["job_id"]),
          {:job_result, clean}
        )

        {:ok, clean}
    end
  end

  @doc """
  Handle one streamed content fragment of a running job. Redacted and broadcast on the
  job's own `"job_chunks:<job_id>"` topic (per-job so a busy gateway request only receives
  its own stream). Chunks are best-effort UX and are never persisted — the final result
  (`handle_result/1`) stays authoritative.
  """
  def handle_chunk(%{"job_id" => job_id} = payload) when is_binary(job_id) do
    {clean, _redactions} = SecretGuard.redact(payload)

    Phoenix.PubSub.broadcast(
      Coordinator.PubSub,
      "job_chunks:" <> job_id,
      {:job_chunk, clean}
    )

    {:ok, clean}
  end

  def handle_chunk(_), do: {:error, :invalid_chunk}

  @doc """
  Handle one progress report from a running job.

  Redacted rather than verified, for the same reason usage and chunks are: a hard reject would
  strand the caller's view of a job that is otherwise running fine, and the fields here are
  counts and identifiers rather than anything a prompt flows into.

  Persisted — unlike `handle_chunk/1` — because the point of it is to survive the caller going
  away and the coordinator restarting. Broadcast as well, so a long-poll waiting on the job
  wakes up rather than sitting until its next timeout.
  """
  def handle_progress(%{"job_id" => job_id} = payload) when is_binary(job_id) do
    {clean, _redactions} = SecretGuard.redact(payload)

    case Jobs.record_progress(job_id, clean) do
      :ok ->
        Phoenix.PubSub.broadcast(
          Coordinator.PubSub,
          Jobs.progress_topic(job_id),
          {:job_progress, clean}
        )

        {:ok, clean}

      {:error, reason} ->
        # Not worth a log line each: a re-leased job's old generation can emit a burst of these
        # before its task is aborted.
        {:error, reason}
    end
  end

  def handle_progress(_), do: {:error, :invalid_progress}

  @doc """
  Handle a job that paused to ask its caller for something.

  Redacted, not verified — and this is the one inbound path where that matters most. The text
  here is written by a model and travels straight into an agent's context, so it is the likeliest
  place for a credential the model read somewhere to come back out. A hard reject would strand
  the job instead of the secret, which is why the posture matches results and chunks.
  """
  def handle_input_request(%{"job_id" => job_id} = payload) when is_binary(job_id) do
    {clean, _redactions} = SecretGuard.redact(payload)

    case Jobs.park_for_input(job_id, clean) do
      {:ok, record} ->
        {:ok, record}

      {:error, :too_many_rounds} ->
        # The model asked once too often. Let the job finish on what it has rather than holding
        # the caller's attention; the worker has already released it, so requeue it to run again
        # with the question in its own history.
        Jobs.requeue(Jobs.get(job_id))
        {:error, :too_many_rounds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_input_request(_), do: {:error, :invalid_input_request}

  # Record the result against the durable job, if it is one we are tracking.
  defp persist_result(%{"job_id" => job_id} = result) when is_binary(job_id) do
    Jobs.complete(job_id, result)
  rescue
    # The worker may report a result for a job we don't persist (e.g. ad-hoc). Don't crash
    # the channel over it.
    _ -> :ok
  end

  defp persist_result(_), do: :ok

  defp validate_registration(%{"worker_id" => id, "execution_mode" => mode})
       when is_binary(id) and mode in ["local_model", "external_provider", "both"],
       do: :ok

  defp validate_registration(_), do: {:error, :invalid_registration}
end
