defmodule Coordinator.Endpoint do
  @moduledoc """
  Phoenix endpoint. Exposes the worker socket (workers connect over WebSocket and exchange
  capability/usage/lease messages) and the OpenAI-compatible HTTP front-door
  (`Coordinator.ApiRouter`). No session/cookie state, and the contract still carries no
  provider secrets: callers present a *gateway* key, never a provider token.
  """
  use Phoenix.Endpoint, otp_app: :coordinator

  socket("/worker", Coordinator.WorkerSocket,
    websocket: true,
    longpoll: false
  )

  # HTTP API: parse JSON bodies, then dispatch to the front-door router.
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Coordinator.ApiRouter)
end
