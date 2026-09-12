defmodule Coordinator.WorkerRegistry do
  @moduledoc """
  The set of connected workers the `Coordinator.Router` routes against — now backed by
  `Coordinator.Presence` so it is **cluster-wide**: every coordinator node sees every worker,
  regardless of which node a worker's WebSocket landed on.

  Reads (`list/0`, `route/1`, `fetch/1`) work from any node. Mutations (`track/2`, `update/2`)
  are owned by the worker's channel process — the Presence tracker — and must be called from
  it (`self()` is the tracking pid). A worker is dropped automatically when its channel
  process dies (Presence untracks on `:DOWN`), replacing the old in-memory `Process.monitor`.
  """

  alias Coordinator.{Presence, Router, Worker}

  @topic "workers"

  @doc "All connected workers across the cluster."
  @spec list() :: [Worker.t()]
  def list do
    Presence.list(@topic)
    |> Enum.map(fn {_id, %{metas: metas}} -> latest(metas) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Route a job against the currently-connected workers (no reservation)."
  def route(job), do: Router.route(job, list())

  @doc "Current snapshot for one worker id (cluster-wide), or nil."
  @spec fetch(String.t()) :: Worker.t() | nil
  def fetch(worker_id) do
    case Presence.get_by_key(@topic, worker_id) do
      %{metas: metas} -> latest(metas)
      _ -> nil
    end
  end

  # ---- mutation: called from the worker's channel process (the tracker) --------------------

  @doc "Track a newly-registered worker. Call from its channel process."
  def track(pid, %Worker{worker_id: id} = worker) do
    Presence.track(pid, @topic, id, meta(worker, pid))
  end

  @doc "Replace the tracked snapshot for a worker. Call from its channel process."
  def update(pid, %Worker{worker_id: id} = worker) do
    Presence.update(pid, @topic, id, meta(worker, pid))
  end

  # `tracked_at` is what makes "most recent" answerable. Presence metas arrive in no
  # particular order, so during a reconnect overlap the winner was whichever the list happened
  # to end with. Wall-clock rather than monotonic: metas are compared across cluster nodes.
  defp meta(worker, pid) do
    %{worker: worker, channel_pid: pid, tracked_at: System.system_time(:microsecond)}
  end

  @doc "Whether another live channel exists for this worker id."
  def other_connection?(worker_id, channel_pid) do
    case Presence.get_by_key(@topic, worker_id) do
      %{metas: metas} -> Enum.any?(metas, &(&1[:channel_pid] != channel_pid))
      _ -> false
    end
  end

  # A worker has a single channel, so normally a single meta. During a brief reconnect overlap
  # two metas can exist under the key; prefer the most recently tracked snapshot.
  defp latest(metas) do
    metas
    |> Enum.filter(&Map.get(&1, :worker))
    # A meta replicated by a node that predates `tracked_at` sorts oldest rather than crashing.
    |> Enum.max_by(&Map.get(&1, :tracked_at, 0), fn -> nil end)
    |> case do
      nil -> nil
      meta -> meta.worker
    end
  end
end
