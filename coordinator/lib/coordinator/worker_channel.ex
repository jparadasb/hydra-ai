defmodule Coordinator.WorkerChannel do
  @moduledoc """
  Per-worker channel. Thin transport wrapper around `Coordinator.WorkerSession`, which runs
  `Coordinator.SecretGuard` on every inbound payload. A worker that tries to push a token is
  refused at join and never registered.

  Topic: `worker:<worker_id>`. The coordinator leases a job by broadcasting a `"job"` event
  on the topic via `lease/2`; the worker replies with a `"result"` message.
  """
  use Phoenix.Channel

  alias Coordinator.WorkerSession

  @impl true
  def join("worker:" <> worker_id, payload, socket) do
    cond do
      # A device-authenticated socket may only join its own authenticated worker's topic.
      socket.assigns[:auth_worker_id] && socket.assigns.auth_worker_id != worker_id ->
        {:error, %{reason: "worker_id_auth_mismatch"}}

      payload["worker_id"] != worker_id ->
        {:error, %{reason: "worker_id_mismatch"}}

      true ->
        case WorkerSession.handle_register(payload, socket.transport_pid) do
          {:ok, worker} ->
            {:ok, %{registered: worker.worker_id}, assign(socket, :worker_id, worker.worker_id)}

          {:error, reason} ->
            {:error, %{reason: to_string(reason)}}
        end
    end
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
      {:ok, _clean} -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("signals", payload, socket) do
    Coordinator.WorkerRegistry.update_signals(socket.assigns.worker_id, payload)
    {:reply, :ok, socket}
  end

  @doc """
  Lease a job to a specific worker by broadcasting a `"job"` event on its topic. The job map
  must conform to `/proto/job.schema.json`.
  """
  def lease(worker_id, %{} = job) do
    Coordinator.Endpoint.broadcast("worker:#{worker_id}", "job", job)
  end
end
