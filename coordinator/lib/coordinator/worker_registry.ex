defmodule Coordinator.WorkerRegistry do
  @moduledoc """
  Live, in-memory registry of connected workers and their non-secret capability snapshots.

  In production each worker holds a persistent Phoenix Channel; this GenServer is the
  source of truth the `Coordinator.Router` queries. Workers are removed when their channel
  process goes down (tracked via `Process.monitor`). No secret ever enters here — callers
  must sanitize registration payloads with `Coordinator.SecretGuard` first.
  """

  use GenServer

  alias Coordinator.{Router, Worker}

  # ---- Client API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Register/replace a worker from a sanitized registration map. `pid` is monitored."
  def register(server \\ __MODULE__, %{} = sanitized_registration, pid \\ nil) do
    GenServer.call(server, {:register, sanitized_registration, pid})
  end

  @doc "Update live scheduling signals for a worker."
  def update_signals(server \\ __MODULE__, worker_id, signals) when is_map(signals) do
    GenServer.call(server, {:update_signals, worker_id, signals})
  end

  def unregister(server \\ __MODULE__, worker_id) do
    GenServer.call(server, {:unregister, worker_id})
  end

  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Route a job against the currently-registered workers."
  def route(server \\ __MODULE__, job), do: Router.route(job, list(server))

  # ---- Server ----

  @impl true
  def init(:ok), do: {:ok, %{workers: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, reg, pid}, _from, state) do
    worker = Worker.from_registration(reg)

    monitors =
      if is_pid(pid) do
        ref = Process.monitor(pid)
        Map.put(state.monitors, ref, worker.worker_id)
      else
        state.monitors
      end

    {:reply, {:ok, worker},
     %{state | workers: Map.put(state.workers, worker.worker_id, worker), monitors: monitors}}
  end

  def handle_call({:update_signals, id, signals}, _from, state) do
    case Map.fetch(state.workers, id) do
      {:ok, %Worker{} = w} ->
        updated = %Worker{
          w
          | inflight: Map.get(signals, "inflight", w.inflight),
            avg_latency_ms: Map.get(signals, "avg_latency_ms", w.avg_latency_ms),
            available: Map.get(signals, "available", w.available)
        }

        {:reply, :ok, %{state | workers: Map.put(state.workers, id, updated)}}

      :error ->
        {:reply, {:error, :unknown_worker}, state}
    end
  end

  def handle_call({:unregister, id}, _from, state) do
    {:reply, :ok, %{state | workers: Map.delete(state.workers, id)}}
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.workers), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {worker_id, monitors} ->
        {:noreply, %{state | workers: Map.delete(state.workers, worker_id), monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
