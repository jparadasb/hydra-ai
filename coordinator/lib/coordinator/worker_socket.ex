defmodule Coordinator.WorkerSocket do
  @moduledoc """
  The worker WebSocket. Each worker joins its own `worker:<worker_id>` channel topic; the
  coordinator leases jobs by broadcasting a `"job"` event on that topic.
  """
  use Phoenix.Socket

  channel("worker:*", Coordinator.WorkerChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  # Anonymous socket: workers are identified by their channel topic, not a socket id.
  @impl true
  def id(_socket), do: nil
end
