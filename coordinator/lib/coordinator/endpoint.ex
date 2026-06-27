defmodule Coordinator.Endpoint do
  @moduledoc """
  Phoenix endpoint. Exposes only the worker socket — workers connect here over WebSocket and
  exchange capability/usage/lease messages. No HTTP API surface and no session/cookie state:
  the contract carries no secrets.
  """
  use Phoenix.Endpoint, otp_app: :coordinator

  socket("/worker", Coordinator.WorkerSocket,
    websocket: true,
    longpoll: false
  )
end
