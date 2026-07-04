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

  # LiveView socket — used by the Oban dashboard mounted under /admin (Coordinator.Web.Router).
  socket("/live", Phoenix.LiveView.Socket, websocket: true, longpoll: false)

  # Landing page assets (priv/site). The page itself is served at "/" by Coordinator.Web.Router;
  # this only serves its static siblings (tailwind.css, logo.png). Public, no session. `only`
  # keeps the door narrow so nothing else under priv is reachable.
  plug(Plug.Static,
    at: "/",
    from: {:coordinator, "priv/site"},
    only: ~w(tailwind.css logo.png)
  )

  # Signed session, required by the admin console: GitHub-OAuth login state + CSRF protection.
  # No provider secret is ever placed here; only the admin's GitHub login.
  @session_options [
    store: :cookie,
    key: "_hydra_admin",
    signing_salt: "hydra-admin-session",
    same_site: "Lax"
  ]

  plug(Plug.Session, @session_options)

  # Parse JSON (API) and form bodies (admin console). `pass: ["*/*"]` lets unmatched content
  # types (e.g. LiveView/Oban socket upgrades) fall through untouched.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Coordinator.Web.Router)
end
