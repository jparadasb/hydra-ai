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
    Presence.track(pid, @topic, id, %{worker: worker})
  end

  @doc "Replace the tracked snapshot for a worker. Call from its channel process."
  def update(pid, %Worker{worker_id: id} = worker) do
    Presence.update(pid, @topic, id, %{worker: worker})
  end

  # A worker has a single channel, so normally a single meta. During a brief reconnect overlap
  # two metas can exist under the key; prefer the most recently tracked snapshot.
  defp latest(metas) do
    metas
    |> Enum.map(&Map.get(&1, :worker))
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end
end
