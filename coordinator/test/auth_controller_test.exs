defmodule Coordinator.Web.AuthControllerTest do
  @moduledoc """
  The GitHub OAuth flow's failure paths, which had no coverage at all — only the redirect and
  the fail-closed 503 were tested, and those live in the router rather than here.

  Every test below is a way in that must stay shut: this controller is the only thing between
  the public internet and `/admin`, where gateway keys are minted and worker trust is granted.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Coordinator.Web.AuthController

  @endpoint Coordinator.Endpoint

  setup do
    Application.put_env(:coordinator, :github_client_id, "cid")
    Application.put_env(:coordinator, :github_client_secret, "secret")
    Application.put_env(:coordinator, :admin_github_users, ["octocat"])

    on_exit(fn ->
      Application.delete_env(:coordinator, :github_client_id)
      Application.delete_env(:coordinator, :github_client_secret)
      Application.delete_env(:coordinator, :admin_github_users)
    end)

    :ok
  end

  describe "the allowlist" do
    test "admits only listed logins, case-insensitively" do
      assert AuthController.allowed?("octocat")
      assert AuthController.allowed?("OctoCat")
      refute AuthController.allowed?("someone-else")
    end

    test "an empty allowlist admits nobody" do
      # Fail closed. An allowlist that defaults to "everyone" on a misconfiguration is the
      # difference between a private console and a public one.
      Application.put_env(:coordinator, :admin_github_users, [])
      refute AuthController.allowed?("octocat")

      Application.delete_env(:coordinator, :admin_github_users)
      refute AuthController.allowed?("octocat")
    end

    test "a non-binary login is refused rather than crashing the callback" do
      refute AuthController.allowed?(nil)
      refute AuthController.allowed?(%{"login" => "octocat"})
    end
  end

  describe "configured?/0" do
    test "requires both halves of the credential" do
      assert AuthController.configured?()

      Application.delete_env(:coordinator, :github_client_secret)
      refute AuthController.configured?()

      Application.put_env(:coordinator, :github_client_secret, "secret")
      Application.delete_env(:coordinator, :github_client_id)
      refute AuthController.configured?()
    end
  end

  describe "the callback" do
    test "a mismatched state is refused" do
      # CSRF on the OAuth flow: an attacker who can make the victim's browser hit the callback
      # with their own code would otherwise log the victim into the attacker's account.
      conn =
        build_conn()
        |> init_test_session(oauth_state: "the-real-state")
        |> get("/auth/github/callback", %{"code" => "c", "state" => "a-different-state"})

      assert conn.status == 403
      refute get_session(conn, :admin_login)
    end

    test "a callback with no state in the session is refused" do
      # A session that never began the flow cannot be completing it.
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get("/auth/github/callback", %{"code" => "c", "state" => "anything"})

      assert conn.status == 403
      refute get_session(conn, :admin_login)
    end

    test "a callback missing code or state is refused" do
      for params <- [%{}, %{"code" => "c"}, %{"state" => "s"}] do
        conn =
          build_conn()
          |> init_test_session(oauth_state: "s")
          |> get("/auth/github/callback", params)

        assert conn.status == 403, "params #{inspect(params)} were not refused"
        refute get_session(conn, :admin_login)
      end
    end

    test "a token exchange that fails does not sign anyone in" do
      # The state matches, so this gets past CSRF and fails at GitHub — no network in tests, so
      # the exchange errors out. The point is where it lands: denied, not signed in.
      conn =
        build_conn()
        |> init_test_session(oauth_state: "matching-state")
        |> get("/auth/github/callback", %{"code" => "c", "state" => "matching-state"})

      assert conn.status == 403
      refute get_session(conn, :admin_login)
    end
  end

  describe "request/2" do
    test "starts the flow with a state it stores in the session" do
      conn = get(build_conn() |> init_test_session(%{}), "/auth/github")

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "https://github.com/login/oauth/authorize"

      state = get_session(conn, :oauth_state)
      assert is_binary(state) and byte_size(state) >= 16
      assert location =~ URI.encode_www_form(state)
    end

    test "two requests get different states" do
      first = get(build_conn() |> init_test_session(%{}), "/auth/github")
      second = get(build_conn() |> init_test_session(%{}), "/auth/github")

      assert get_session(first, :oauth_state) != get_session(second, :oauth_state)
    end
  end

  describe "logout" do
    test "drops the session" do
      conn =
        build_conn()
        |> init_test_session(admin_login: "octocat")
        |> get("/auth/logout")

      assert redirected_to(conn) == "/"
      # `configure_session(drop: true)` drops the cookie when the response is sent, so the
      # value is still readable on this conn — the instruction is what to assert.
      assert conn.private[:plug_session_info] == :drop
    end
  end
end
