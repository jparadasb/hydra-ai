defmodule Coordinator.Web.AuthController do
  @moduledoc """
  Minimal GitHub OAuth (web application flow) for the admin console — no extra auth framework.

    * `GET /auth/github`          — redirect to GitHub's authorize page (with a CSRF `state`).
    * `GET /auth/github/callback` — verify `state`, exchange `code` for a token, fetch the user,
      check the login against the allowlist (`:admin_github_users`), and stash it in the session.
    * `GET /auth/logout`          — drop the session.

  The OAuth access token is used once (server-side) to read the user's login and is never
  persisted — it is not a provider token and never touches a worker.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"
  @user_url "https://api.github.com/user"

  def request(conn, _params) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "client_id" => client_id(),
        "redirect_uri" => callback_url(conn),
        "scope" => "read:user",
        "state" => state,
        "allow_signup" => "false"
      })

    conn
    |> put_session(:oauth_state, state)
    |> redirect(external: @authorize_url <> "?" <> query)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :oauth_state)

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(state, expected),
         {:ok, token} <- exchange_code(code, conn),
         {:ok, login} <- fetch_login(token),
         true <- allowed?(login) do
      conn
      |> configure_session(renew: true)
      |> delete_session(:oauth_state)
      |> put_session(:admin_login, login)
      |> redirect(to: "/admin")
    else
      false -> deny(conn, "not authorized")
      {:error, reason} -> deny(conn, "github login failed: #{inspect(reason)}")
    end
  end

  def callback(conn, _params), do: deny(conn, "missing code/state")

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  # ---- allowlist + config -------------------------------------------------------------------

  @doc "Is the GitHub OAuth app configured (client id + secret present)?"
  def configured?, do: client_id() != nil and client_secret() != nil

  @doc "Is this GitHub login on the admin allowlist? Empty allowlist => nobody (fail closed)."
  def allowed?(login) when is_binary(login) do
    login = String.downcase(login)
    login in Enum.map(admin_users(), &String.downcase/1)
  end

  # ---- GitHub calls -------------------------------------------------------------------------

  defp exchange_code(code, conn) do
    resp =
      Req.post(@token_url,
        headers: [{"accept", "application/json"}],
        json: %{
          "client_id" => client_id(),
          "client_secret" => client_secret(),
          "code" => code,
          "redirect_uri" => callback_url(conn)
        }
      )

    case resp do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{body: body}} ->
        {:error, {:token_exchange, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_login(token) do
    resp =
      Req.get(@user_url,
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/vnd.github+json"},
          {"user-agent", "hydra-coordinator"}
        ]
      )

    case resp do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) -> {:ok, login}
      {:ok, %{body: body}} -> {:error, {:user_lookup, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deny(conn, message) do
    conn
    |> put_status(403)
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Admin login denied: #{message}")
  end

  defp callback_url(conn) do
    base = Application.get_env(:coordinator, :admin_base_url) || default_base(conn)
    String.trim_trailing(base, "/") <> "/auth/github/callback"
  end

  defp default_base(conn), do: "#{conn.scheme}://#{conn.host}:#{conn.port}"

  defp client_id, do: Application.get_env(:coordinator, :github_client_id)
  defp client_secret, do: Application.get_env(:coordinator, :github_client_secret)
  defp admin_users, do: Application.get_env(:coordinator, :admin_github_users, [])
end
