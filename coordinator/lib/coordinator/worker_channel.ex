defmodule Coordinator.WorkerChannel do
  @moduledoc """
  Per-worker channel. The channel process is the **owner** of its worker's cluster-wide
  presence entry (`Coordinator.Presence` via `Coordinator.WorkerRegistry`): it tracks the
  worker on join, keeps its live `inflight` count (it sees each job pushed out and each result
  come back), applies admin policy changes pushed to it, and is untracked automatically when
  it dies. Registration payloads pass through `Coordinator.WorkerSession`, which runs
  `Coordinator.SecretGuard` first — a worker that tries to push a token is refused at join.

  Topic: `worker:<worker_id>`. The coordinator leases a job by broadcasting a `"job"` event on
  the topic via `lease/2` (cluster-wide PubSub, so it reaches the node holding the channel);
  the worker replies with a `"result"` message.
  """
  use Phoenix.Channel
  require Logger

  alias Coordinator.{Jobs, WorkerRegistry, WorkerSession, WorkerSignals}

  # Intercept job lifecycle pushes so channel-owned inflight stays accurate.
  intercept(["job", "cancel"])

  @impl true
  def join("worker:" <> worker_id, payload, socket) do
    cond do
      # A device-authenticated socket may only join its own authenticated worker's topic.
      socket.assigns[:auth_worker_id] && socket.assigns.auth_worker_id != worker_id ->
        {:error, %{reason: "worker_id_auth_mismatch"}}

      payload["worker_id"] != worker_id ->
        {:error, %{reason: "worker_id_mismatch"}}

      true ->
        case WorkerSession.handle_register(payload) do
          {:ok, worker} ->
            # Track after join returns (Presence.track must run from the channel process,
            # after the socket is in place).
            send(self(), :after_join)

            {:ok, %{registered: worker.worker_id},
             socket
             |> assign(:worker_id, worker.worker_id)
             |> assign(:worker, worker)
             # lease -> when it went out, so the coordinator can measure how long the worker
             # took rather than asking the worker how fast it is.
             |> assign(:active_leases, %{})
             |> assign(:completions, [])}

          {:error, reason} ->
            {:error, %{reason: to_string(reason)}}
        end
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    worker = socket.assigns.worker
    {:ok, _ref} = WorkerRegistry.track(self(), worker)
    # Admin policy changes for this worker are delivered here regardless of which node the
    # change was made on (cluster-wide PubSub).
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "worker_control:#{worker.worker_id}")
    {:noreply, socket}
  end

  # Admin granted new accepted privacy levels (from Coordinator.WorkerPolicies).
  def handle_info({:set_accepted_levels, levels}, socket) do
    worker = %{socket.assigns.worker | accepted_job_levels: levels}
    WorkerRegistry.update(self(), worker)
    {:noreply, assign(socket, :worker, worker)}
  end

  # Admin changed this worker's routing trust (from Coordinator.WorkerPolicies).
  def handle_info({:set_trust_level, trust}, socket) do
    worker = %{socket.assigns.worker | trust_level: trust}
    WorkerRegistry.update(self(), worker)
    {:noreply, assign(socket, :worker, worker)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Forward the leased job to the worker, count it as inflight, and start its clock.
  @impl true
  def handle_out("job", payload, socket) do
    push(socket, "job", payload)
    worker = %{socket.assigns.worker | inflight: socket.assigns.worker.inflight + 1}
    WorkerRegistry.update(self(), worker)

    active_leases =
      Map.put(
        socket.assigns.active_leases,
        {payload["job_id"], payload["lease_id"]},
        now_ms()
      )

    {:noreply, socket |> assign(:worker, worker) |> assign(:active_leases, active_leases)}
  end

  def handle_out("cancel", payload, socket) do
    push(socket, "cancel", payload)

    if Map.get(socket.assigns.worker, :supports_cancel_ack, false) do
      {:noreply, socket}
    else
      {:noreply, finish_lease(socket, payload["job_id"], payload["lease_id"])}
    end
  end

  @impl true
  def handle_in("usage", payload, socket) do
    # Usage reports are redacted, never refused: losing one to a false positive loses
    # accounting and gains nothing.
    {:ok, _clean} = WorkerSession.handle_usage(payload)
    {:reply, :ok, socket}
  end

  # Refresh the advertised model catalog without forcing a reconnect. Identity remains pinned
  # to the authenticated channel topic; inflight is channel-owned and therefore preserved.
  def handle_in("registration", %{"worker_id" => worker_id} = payload, socket)
      when worker_id == socket.assigns.worker_id do
    case WorkerSession.handle_register(payload) do
      {:ok, refreshed} ->
        worker = %{refreshed | inflight: socket.assigns.worker.inflight}
        WorkerRegistry.update(self(), worker)
        {:reply, :ok, assign(socket, :worker, worker)}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("cancelled", %{"job_id" => job_id, "lease_id" => lease_id} = payload, socket)
      when is_binary(job_id) and is_binary(lease_id) do
    case Coordinator.SecretGuard.verify(payload) do
      :ok -> {:reply, :ok, finish_lease(socket, job_id, lease_id)}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("cancelled", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_cancellation_ack"}}, socket}

  def handle_in(
        "lease_heartbeat",
        %{"job_id" => job_id, "lease_id" => lease_id} = payload,
        socket
      )
      when is_binary(job_id) and is_binary(lease_id) do
    with :ok <- Coordinator.SecretGuard.verify(payload),
         :ok <- Jobs.renew_lease(socket.assigns.worker_id, job_id, lease_id) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("lease_heartbeat", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_lease_heartbeat"}}, socket}

  def handle_in("registration", _payload, socket),
    do: {:reply, {:error, %{reason: "worker_id_mismatch"}}, socket}

  # Streamed content fragments. No reply: a per-token ack round trip would double the
  # message rate for zero value — the worker fires and forgets, the final "result" is
  # the acknowledged message.
  def handle_in("result_chunk", payload, socket) do
    WorkerSession.handle_chunk(payload)
    {:noreply, socket}
  end

  def handle_in("result", payload, socket) do
    case WorkerSession.handle_result(payload) do
      {:ok, _clean} ->
        {:reply, :ok, finish_result(socket, payload)}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, finish_result(socket, payload)}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A worker may take itself out of rotation; it may not tell us how fast it is. Latency is
  # measured here (lease out -> result in), so `avg_latency_ms` in this payload is ignored.
  def handle_in("signals", payload, socket) do
    w = socket.assigns.worker
    worker = %{w | available: Map.get(payload, "available", w.available)}

    WorkerRegistry.update(self(), worker)
    {:reply, :ok, assign(socket, :worker, worker)}
  end

  @impl true
  def terminate(_reason, socket) do
    if worker_id = socket.assigns[:worker_id] do
      if not WorkerRegistry.other_connection?(worker_id, self()) do
        case Jobs.reclaim_worker_leases(worker_id) do
          :ok -> :ok
          {:error, reason} -> Logger.error("worker lease reclaim failed: #{inspect(reason)}")
        end
      end
    end

    :ok
  end

  @doc """
  Lease a job to a specific worker by broadcasting a `"job"` event on its topic. The job map
  must conform to `/proto/job.schema.json`. Cluster-wide: reaches the channel on whatever node
  the worker is connected to.
  """
  def lease(worker_id, %{} = job) do
    Coordinator.Endpoint.broadcast("worker:#{worker_id}", "job", job)
  end

  @doc "Tell a worker to abort an in-flight or queued job. Safe when job already finished."
  def cancel(worker_id, job_id, lease_id)
      when is_binary(worker_id) and is_binary(job_id) and is_binary(lease_id) do
    Coordinator.Endpoint.broadcast(
      "worker:#{worker_id}",
      "cancel",
      %{"job_id" => job_id, "lease_id" => lease_id}
    )
  end

  defp finish_job(socket, job_id, outcome \\ :timeout) do
    socket.assigns.active_leases
    |> Map.keys()
    |> Enum.filter(fn {id, _lease_id} -> id == job_id end)
    |> Enum.reduce(socket, fn {_id, lease_id}, current ->
      finish_lease(current, job_id, lease_id, outcome)
    end)
  end

  defp finish_result(socket, %{"job_id" => job_id, "lease_id" => lease_id} = payload)
       when is_binary(job_id) and is_binary(lease_id),
       do: finish_lease(socket, job_id, lease_id, WorkerSignals.outcome(payload))

  defp finish_result(socket, %{"job_id" => job_id} = payload) when is_binary(job_id),
    do: finish_job(socket, job_id, WorkerSignals.outcome(payload))

  defp finish_result(socket, _payload), do: socket

  # A lease that ends without a result — a cancellation, or a worker that went away — counts
  # as the worker failing to deliver, but carries no latency sample: the elapsed time measures
  # how long we waited, not how fast it is.
  defp finish_lease(socket, job_id, lease_id),
    do: finish_lease(socket, job_id, lease_id, :timeout)

  defp finish_lease(socket, job_id, lease_id, outcome) do
    lease = {job_id, lease_id}

    case Map.pop(socket.assigns.active_leases, lease) do
      {nil, _} ->
        socket

      {started_at, remaining} ->
        now = now_ms()
        w = socket.assigns.worker
        completions = WorkerSignals.record_completion(socket.assigns.completions, now)

        worker = %{
          w
          | inflight: max(w.inflight - 1, 0),
            avg_latency_ms: latency_for(w, outcome, now - started_at),
            requests_last_hour: WorkerSignals.requests_in_window(completions, now),
            recent_failures: WorkerSignals.record_outcome(w.recent_failures, outcome)
        }

        WorkerRegistry.update(self(), worker)

        socket
        |> assign(:worker, worker)
        |> assign(:active_leases, remaining)
        |> assign(:completions, completions)
    end
  end

  # Only a delivered result says anything about throughput.
  defp latency_for(worker, :timeout, _elapsed), do: worker.avg_latency_ms

  defp latency_for(worker, _outcome, elapsed),
    do: WorkerSignals.observe_latency(worker.avg_latency_ms, elapsed)
end
