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

  alias Coordinator.{WorkerRegistry, WorkerSession}

  # Intercept outgoing "job" so the channel can bump inflight as it forwards the lease.
  intercept(["job"])

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
             socket |> assign(:worker_id, worker.worker_id) |> assign(:worker, worker)}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Forward the leased job to the worker and count it as inflight.
  @impl true
  def handle_out("job", payload, socket) do
    push(socket, "job", payload)
    worker = %{socket.assigns.worker | inflight: socket.assigns.worker.inflight + 1}
    WorkerRegistry.update(self(), worker)
    {:noreply, assign(socket, :worker, worker)}
  end

  @impl true
  def handle_in("usage", payload, socket) do
    case WorkerSession.handle_usage(payload) do
      {:ok, _clean} -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("result", payload, socket) do
    case WorkerSession.handle_result(payload) do
      {:ok, _clean} ->
        worker = %{
          socket.assigns.worker
          | inflight: max(socket.assigns.worker.inflight - 1, 0)
        }

        WorkerRegistry.update(self(), worker)
        {:reply, :ok, assign(socket, :worker, worker)}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("signals", payload, socket) do
    w = socket.assigns.worker

    worker = %{
      w
      | avg_latency_ms: Map.get(payload, "avg_latency_ms", w.avg_latency_ms),
        available: Map.get(payload, "available", w.available)
    }

    WorkerRegistry.update(self(), worker)
    {:reply, :ok, assign(socket, :worker, worker)}
  end

  @doc """
  Lease a job to a specific worker by broadcasting a `"job"` event on its topic. The job map
  must conform to `/proto/job.schema.json`. Cluster-wide: reaches the channel on whatever node
  the worker is connected to.
  """
  def lease(worker_id, %{} = job) do
    Coordinator.Endpoint.broadcast("worker:#{worker_id}", "job", job)
  end
end
