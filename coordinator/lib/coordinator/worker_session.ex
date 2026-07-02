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

  Every inbound payload passes through `Coordinator.SecretGuard.verify/1` first; a worker
  that tries to push a token is refused, never registered.
  """

  alias Coordinator.{SecretGuard, WorkerRegistry}

  @doc """
  Handle a worker's registration. Rejects any payload carrying secret-shaped data, then
  sanitizes (belt and suspenders) and registers the worker, monitoring `pid`.
  """
  def handle_register(payload, pid \\ nil, registry \\ WorkerRegistry) do
    with :ok <- SecretGuard.verify(payload),
         :ok <- validate_registration(payload) do
      sanitized = payload |> SecretGuard.sanitize() |> apply_admin_privacy()
      WorkerRegistry.register(registry, sanitized, pid)
    end
  end

  # Privacy acceptance is decided by the admin (`Coordinator.WorkerPolicies`), not the
  # worker: whatever levels the registration declares are replaced with the admin-granted
  # ones (public-only until an admin raises it).
  defp apply_admin_privacy(%{"worker_id" => worker_id} = payload) do
    levels = Coordinator.WorkerPolicies.accepted_levels(worker_id)

    Map.update(
      payload,
      "privacy",
      %{"accepted_job_levels" => levels},
      &Map.put(&1, "accepted_job_levels", levels)
    )
  end

  @doc "Handle an aggregated usage report (no secrets). Returns the sanitized report."
  def handle_usage(payload) do
    case SecretGuard.verify(payload) do
      :ok -> {:ok, SecretGuard.sanitize(payload)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Handle a normalized job result from a worker. Broadcasts the (sanitized, secret-free)
  result on the `"job_results"` PubSub topic so schedulers/tests can observe completions.
  """
  def handle_result(payload) do
    case SecretGuard.verify(payload) do
      :ok ->
        clean = SecretGuard.sanitize(payload)
        persist_result(clean)
        release_reservation(clean)
        Phoenix.PubSub.broadcast(Coordinator.PubSub, "job_results", {:job_result, clean})
        {:ok, clean}

      {:error, _} = err ->
        err
    end
  end

  # This attempt is done, so free the worker's inflight slot (see WorkerRegistry.reserve/2). A
  # requeued job simply reserves again when it is re-leased. Best-effort: unknown jobs are
  # ignored (the worker may report a result for a job we don't persist).
  defp release_reservation(%{"job_id" => job_id}) when is_binary(job_id) do
    case Coordinator.Jobs.get(job_id) do
      %{worker_id: wid} when is_binary(wid) -> Coordinator.WorkerRegistry.release(wid)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp release_reservation(_), do: :ok

  # Record the result against the durable job, if it is one we are tracking.
  defp persist_result(%{"job_id" => job_id} = result) when is_binary(job_id) do
    Coordinator.Jobs.complete(job_id, result)
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
