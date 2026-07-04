defmodule Coordinator.Web.RouterTest do
  @moduledoc """
  Exercises the admin web surface in-process (Phoenix.ConnTest, no bound port):

    * the front-door still answers under the fallback forward (`/health`),
    * the admin console lists/creates/reveals/revokes API keys (open on loopback dev),
    * the real Oban dashboard mounts under `/admin/oban`,
    * admin auth, when enforced (prod), bounces anonymous callers to the GitHub login.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Coordinator.{ApiToken, Repo}

  @endpoint Coordinator.Endpoint

  setup do
    Application.delete_env(:coordinator, :admin_auth_required)

    on_exit(fn ->
      Application.delete_env(:coordinator, :admin_auth_required)
      Application.delete_env(:coordinator, :github_client_id)
      Application.delete_env(:coordinator, :github_client_secret)
      Application.delete_env(:coordinator, :admin_github_users)
      Repo.delete_all(ApiToken)
    end)

    :ok
  end

  test "the OpenAI front-door is still reachable via the fallback forward" do
    conn = get(build_conn(), "/health")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "admin console renders on loopback dev (no auth enforced)" do
    conn = get(build_conn(), "/admin")
    assert conn.status == 200
    assert conn.resp_body =~ "Issue a key"
    assert conn.resp_body =~ "/admin/oban"
  end

  test "create then reveal a key once, then revoke it" do
    # GET first to establish the session + CSRF token, then POST the form.
    conn = get(build_conn(), "/admin")
    csrf = csrf_token(conn.resp_body)

    conn =
      conn
      |> recycle()
      |> post("/admin/tokens", %{"_csrf_token" => csrf, "label" => "web-test-key"})

    assert redirected_to(conn) == "/admin"

    # The redirect target reveals the plaintext exactly once (carried in the session).
    revealed = conn |> recycle() |> get("/admin")
    assert revealed.resp_body =~ "will not be shown again"
    plaintext = Regex.run(~r/<code[^>]*>(hydra_sk_[^<]+)</, revealed.resp_body) |> Enum.at(1)
    assert is_binary(plaintext)

    # A second load no longer shows it (one-shot).
    again = revealed |> recycle() |> get("/admin")
    refute again.resp_body =~ "will not be shown again"
    assert again.resp_body =~ "web-test-key"

    # Revoke it.
    token = Repo.one(ApiToken)
    csrf2 = csrf_token(again.resp_body)

    revoked =
      again |> recycle() |> post("/admin/tokens/#{token.id}/revoke", %{"_csrf_token" => csrf2})

    assert redirected_to(revoked) == "/admin"
    assert Repo.get(ApiToken, token.id).revoked_at
  end

  test "Oban dashboard is mounted under /admin/oban and behind the admin gate" do
    # The dashboard route exists and shares the /admin auth pipeline: when auth is enforced an
    # anonymous caller is redirected to login *before* the LiveView (and its Oban.Met metrics,
    # which auto-start only outside testing mode) are ever reached.
    Application.put_env(:coordinator, :admin_auth_required, true)
    Application.put_env(:coordinator, :github_client_id, "cid")
    Application.put_env(:coordinator, :github_client_secret, "secret")
    Application.put_env(:coordinator, :admin_github_users, ["octocat"])

    conn = get(build_conn(), "/admin/oban")
    assert redirected_to(conn) == "/auth/github"
  end

  test "dashboard page and stats JSON render under /admin" do
    conn = get(build_conn(), "/admin/dashboard")
    assert conn.status == 200
    assert conn.resp_body =~ "chart-throughput"
    assert conn.resp_body =~ "Connected workers"

    # The page's JS polls with an explicit JSON accept header; the browser pipeline must not
    # 406 it (regression: `accepts ["html"]` rejected exactly this request in prod).
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/admin/stats")

    assert conn.status == 200
    stats = Jason.decode!(conn.resp_body)
    assert is_list(stats["workers"])
    assert is_map(stats["jobs"])
    assert is_list(stats["throughput"])
  end

  test "workers admin page lists enrolled workers and saves a policy" do
    key =
      %Coordinator.WorkerKey{}
      |> Coordinator.WorkerKey.changeset(%{
        worker_id: "w-admin-test",
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        status: "trusted"
      })
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(Coordinator.WorkerKey) end)
    assert key.accepted_job_levels == ["public"]

    conn = get(build_conn(), "/admin/workers")
    assert conn.status == 200
    assert conn.resp_body =~ "w-admin-test"
    assert conn.resp_body =~ "Accepted job levels"

    csrf = csrf_token(conn.resp_body)

    conn =
      conn
      |> recycle()
      |> post("/admin/workers/w-admin-test/policy", %{
        "_csrf_token" => csrf,
        "levels" => ["public", "private"]
      })

    assert redirected_to(conn) == "/admin/workers"

    assert Repo.get(Coordinator.WorkerKey, "w-admin-test").accepted_job_levels ==
             ["public", "private"]
  end

  test "when admin auth is enforced, anonymous callers are redirected to GitHub login" do
    Application.put_env(:coordinator, :admin_auth_required, true)
    Application.put_env(:coordinator, :github_client_id, "cid")
    Application.put_env(:coordinator, :github_client_secret, "secret")
    Application.put_env(:coordinator, :admin_github_users, ["octocat"])

    conn = get(build_conn(), "/admin")
    assert redirected_to(conn) == "/auth/github"
  end

  test "enforced but unconfigured OAuth fails closed (503)" do
    Application.put_env(:coordinator, :admin_auth_required, true)

    conn = get(build_conn(), "/admin")
    assert conn.status == 503
  end

  defp csrf_token(html) do
    Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html) |> Enum.at(1)
  end
end
