defmodule Coordinator.Presence do
  @moduledoc """
  Cluster-wide presence of connected workers.

  Each connected worker has exactly one Phoenix channel process, on the node its WebSocket
  landed on. That process is the sole owner of the worker's presence entry: it tracks the
  worker under topic `"workers"` (key = `worker_id`) with the full non-secret
  `Coordinator.Worker` snapshot as metadata, and updates it as inflight / signals / admin
  policy change. `Phoenix.Presence` replicates this across the libcluster-connected BEAM
  cluster (CRDT, self-healing), so **any** node's `Coordinator.Router` and `/admin` dashboard
  see every worker — not just the ones connected to that node.

  Nothing secret lives in the metadata: the snapshot is capabilities + usage metadata only,
  the same data `Coordinator.WorkerRegistry` held in memory before.
  """
  use Phoenix.Presence, otp_app: :coordinator, pubsub_server: Coordinator.PubSub

  @topic "workers"

  @doc "The presence topic all workers are tracked under."
  def topic, do: @topic
end
