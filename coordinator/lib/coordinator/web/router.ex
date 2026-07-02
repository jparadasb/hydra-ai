defmodule Coordinator.Web.Router do
  @moduledoc """
  HTTP router for the coordinator's web surface. Three concerns live here:

    * `/auth/*`  — GitHub OAuth login flow for the admin console (`Coordinator.Web.AuthController`).
    * `/admin/*` — admin console: issue/revoke gateway API keys, and the real Oban dashboard.
      Gated by `Coordinator.Web.AdminAuth` (enforced only where `:admin_auth_required` is set —
      i.e. prod; open on loopback dev).
    * everything else — forwarded to the OpenAI-compatible front-door (`Coordinator.ApiRouter`),
      which serves `/health` and `/v1/chat/completions`.
  """
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :admin do
    plug(Coordinator.Web.AdminAuth)
  end

  scope "/auth", Coordinator.Web do
    pipe_through(:browser)

    get("/github", AuthController, :request)
    get("/github/callback", AuthController, :callback)
    get("/logout", AuthController, :logout)
  end

  scope "/admin", Coordinator.Web do
    pipe_through([:browser, :admin])

    get("/", TokenController, :index)
    post("/tokens", TokenController, :create)
    post("/tokens/:id/revoke", TokenController, :revoke)

    # Operational dashboard: workers connected vs pending/processed jobs (+ JSON it polls).
    get("/dashboard", DashboardController, :index)
    get("/stats", DashboardController, :stats)
  end

  # The Oban dashboard (LiveView, self-served assets). Same auth gate as the rest of /admin.
  scope "/admin" do
    pipe_through([:browser, :admin])

    oban_dashboard("/oban")
  end

  # Fallback: the public OpenAI-compatible API. Declared last so /admin and /auth win first.
  forward("/", Coordinator.ApiRouter)
end
