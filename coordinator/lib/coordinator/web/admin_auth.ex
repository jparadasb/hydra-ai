defmodule Coordinator.Web.AdminAuth do
  @moduledoc """
  Gate for the `/admin` console. Enforcement is environment-driven so the requirement to log in
  applies **only where `:admin_auth_required` is true** (set in prod) — on loopback dev the
  console is open, matching the front-door's "open on loopback" posture.

  When enforced, a request must carry a session `:admin_login` that is on the allowlist
  (`:admin_github_users`), established by the GitHub OAuth flow in `Coordinator.Web.AuthController`.
  Otherwise the caller is redirected to `/auth/github` to log in. If enforcement is on but the
  OAuth app is not configured, every request is denied (fail closed).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Coordinator.Web.AuthController

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if required?() do
      enforce(conn)
    else
      assign(conn, :current_admin, get_session(conn, :admin_login) || "dev")
    end
  end

  defp enforce(conn) do
    login = get_session(conn, :admin_login)

    cond do
      not AuthController.configured?() ->
        conn
        |> send_resp(503, "admin login is enabled but the GitHub OAuth app is not configured")
        |> halt()

      is_binary(login) and AuthController.allowed?(login) ->
        assign(conn, :current_admin, login)

      true ->
        conn
        |> redirect(to: "/auth/github")
        |> halt()
    end
  end

  @doc "Is admin login enforced in this environment? (True in prod; false on loopback dev.)"
  def required?, do: Application.get_env(:coordinator, :admin_auth_required, false)
end
