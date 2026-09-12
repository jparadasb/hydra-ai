defmodule Coordinator.Endpoint do
  @moduledoc """
  Phoenix endpoint. Exposes the worker socket (workers connect over WebSocket and exchange
  capability/usage/lease messages) and the OpenAI-compatible HTTP front-door
  (`Coordinator.ApiRouter`). No session/cookie state, and the contract still carries no
  provider secrets: callers present a *gateway* key, never a provider token.
  """
  use Phoenix.Endpoint, otp_app: :coordinator

  # `connect_info: [:peer_data, :x_headers]` is what makes a worker's peer IP available to
  # `Coordinator.WorkerSocket` — without it the connection is anonymous and abuse from a
  # specific host cannot be investigated after the fact.
  socket("/worker", Coordinator.WorkerSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
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

  # `pass: ["*/*"]` in `parser_opts/0` below lets unmatched content types (e.g. LiveView/Oban
  # socket upgrades) fall through untouched.
  plug(:parse_body)

  plug(Coordinator.Web.Router)

  # Parse JSON (API) and form bodies (admin console) with a capped body length.
  #
  # Plug's default `:length` is 8 MB and a front-door body is persisted verbatim into
  # `jobs.payload`, so the default let one caller write 8 MB rows as fast as they could send
  # them. Options passed to `plug Plug.Parsers, ...` are baked in when this module compiles,
  # which would leave the cap unconfigurable in a release; they are built on first use instead
  # and cached in `:persistent_term`, so a release can still set HYDRA_MAX_BODY_BYTES and the
  # cost is paid once rather than per request.
  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, parser_opts())
  rescue
    # `Plug.Parsers` signals an over-cap body by raising. The endpoint renders no error
    # formats, so letting it propagate would turn a 413 into a 500; answer in the same
    # OpenAI-shaped envelope every other front-door error uses.
    Plug.Parsers.RequestTooLargeError ->
      body = %{
        "error" => %{
          "message" => "request body too large",
          "type" => "invalid_request_error"
        }
      }

      # The rest of the over-cap body is never read, so this connection cannot be reused for
      # a following request — say so rather than leaving the client waiting on a socket whose
      # unread bytes will be parsed as the next request.
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("connection", "close")
      |> send_resp(413, Jason.encode!(body))
      |> halt()
  end

  defp parser_opts do
    case :persistent_term.get({__MODULE__, :parser_opts}, nil) do
      nil ->
        opts =
          Plug.Parsers.init(
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            length: Application.get_env(:coordinator, :max_body_bytes, 2_000_000),
            json_decoder: Jason
          )

        :persistent_term.put({__MODULE__, :parser_opts}, opts)
        opts

      opts ->
        opts
    end
  end
end
