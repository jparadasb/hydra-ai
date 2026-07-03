defmodule Coordinator.ApiRouterTest do
  @moduledoc """
  Tests the OpenAI-compatible HTTP front-door. Drives the router through Plug.Parsers (as the
  endpoint does) and simulates a worker by broadcasting a `{:job_result, ...}` for the job the
  request just created.
  """
  # async: false — exercises the shared Repo + the :api_token application env.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Repo
  import Ecto.Query

  @parser_opts Plug.Parsers.init(parsers: [:json], pass: ["application/json"], json_decoder: Jason)

  setup do
    # Default to an open door; individual tests opt into a key.
    Application.delete_env(:coordinator, :api_token)
    Application.delete_env(:coordinator, :require_api_token)

    on_exit(fn ->
      Application.delete_env(:coordinator, :api_token)
      Application.delete_env(:coordinator, :require_api_token)
      Repo.delete_all(Coordinator.ApiToken)
    end)

    :ok
  end

  defp post(path, body, headers \\ []) do
    conn =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    conn
    |> Plug.Parsers.call(@parser_opts)
    |> Coordinator.ApiRouter.call(Coordinator.ApiRouter.init([]))
  end

  # Find the `chat` job carrying our unique marker. Concurrent tests also create chat jobs, so
  # we match on the message content, not just "the newest one".
  defp find_job_id(nonce) do
    from(j in JobRecord, where: j.capability == "chat", order_by: [desc: j.inserted_at], limit: 50)
    |> Repo.all()
    |> Enum.find(fn j -> get_in(j.payload, ["messages", Access.at(0), "content"]) == nonce end)
    |> case do
      nil -> nil
      j -> j.id
    end
  end

  test "GET /health is ok" do
    conn = conn(:get, "/health") |> Coordinator.ApiRouter.call(Coordinator.ApiRouter.init([]))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "unknown path 404s with an OpenAI-shaped error" do
    conn = post("/v1/nope", %{})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["type"] == "invalid_request_error"
  end

  test "missing messages 400s" do
    conn = post("/v1/chat/completions", %{"model" => "x"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "messages"
  end

  test "no worker -> 504 within the per-request timeout" do
    # Tiny timeout so the test is fast; this still creates a real pending job + waits.
    conn =
      post("/v1/chat/completions", %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "timeout_ms" => 150
      })

    assert conn.status == 504
    assert Jason.decode!(conn.resp_body)["error"]["type"] == "timeout"
  end

  test "happy path maps a worker result into an OpenAI completion" do
    nonce = "apitest-#{System.unique_integer([:positive])}"

    # Run the request concurrently; meanwhile find its job and broadcast a worker result.
    task =
      Task.async(fn ->
        post("/v1/chat/completions", %{
          "messages" => [%{"role" => "user", "content" => nonce}],
          "model" => "test-model",
          "timeout_ms" => 5000
        })
      end)

    job_id = wait_for(fn -> find_job_id(nonce) end)

    Phoenix.PubSub.broadcast(Coordinator.PubSub, "job_results", {
      :job_result,
      %{
        "job_id" => job_id,
        "status" => "ok",
        "output" => %{"content" => "hi there"},
        "usage" => %{
          "provider" => "ollama",
          "model" => "llama3",
          "input_tokens" => 3,
          "output_tokens" => 2,
          "latency_ms" => 12.0
        }
      }
    })

    conn = Task.await(task, 6000)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "chat.completion"
    assert body["id"] == "chatcmpl-" <> job_id
    assert body["model"] == "llama3"
    assert hd(body["choices"])["message"]["content"] == "hi there"
    assert body["usage"]["total_tokens"] == 5
  end

  test "bearer token required when :api_token is set" do
    Application.put_env(:coordinator, :api_token, "secret-key")
    msg = %{"messages" => [%{"role" => "user", "content" => "hi"}], "timeout_ms" => 150}

    assert post("/v1/chat/completions", msg).status == 401
    assert post("/v1/chat/completions", msg, [{"authorization", "Bearer wrong"}]).status == 401
    # Correct key passes auth (then 504s: no worker — proves it got past the gate).
    assert post("/v1/chat/completions", msg, [{"authorization", "Bearer secret-key"}]).status == 504
  end

  test "an admin-issued DB key authorizes when require_api_token is on" do
    Application.put_env(:coordinator, :require_api_token, true)
    {:ok, plaintext, _} = Coordinator.ApiTokens.create("test-key")
    msg = %{"messages" => [%{"role" => "user", "content" => "hi"}], "timeout_ms" => 150}

    # No credential -> blocked.
    assert post("/v1/chat/completions", msg).status == 401
    # Bad credential -> blocked.
    assert post("/v1/chat/completions", msg, [{"authorization", "Bearer nope"}]).status == 401
    # Valid DB key passes the gate (then 504s: no worker connected).
    assert post("/v1/chat/completions", msg, [{"authorization", "Bearer " <> plaintext}]).status ==
             504
  end

  test "a revoked DB key no longer authorizes" do
    Application.put_env(:coordinator, :require_api_token, true)
    {:ok, plaintext, record} = Coordinator.ApiTokens.create("revoke-me")
    :ok = Coordinator.ApiTokens.revoke(record.id)
    msg = %{"messages" => [%{"role" => "user", "content" => "hi"}], "timeout_ms" => 150}

    assert post("/v1/chat/completions", msg, [{"authorization", "Bearer " <> plaintext}]).status ==
             401
  end

  describe "GET /v1/models" do
    setup do
      Coordinator.WorkerTestHelper.track(%{
        "worker_id" => "worker-models-test",
        "execution_mode" => "local_model",
        "provider" => %{"name" => "ollama"},
        "models" => [
          %{"name" => "llama3", "capabilities" => ["chat"], "uses_external_provider" => false},
          %{"name" => "embed-x", "capabilities" => ["embeddings"], "uses_external_provider" => false}
        ]
      })

      :ok
    end

    defp get_json(path, headers \\ []) do
      conn = conn(:get, path)
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      Coordinator.ApiRouter.call(conn, Coordinator.ApiRouter.init([]))
    end

    test "lists models advertised for the routing capability, OpenAI-shaped" do
      conn = get_json("/v1/models")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "list"
      ids = Enum.map(body["data"], & &1["id"])
      assert "llama3" in ids
      # Models not serving the routing capability ("chat") are excluded.
      refute "embed-x" in ids

      model = Enum.find(body["data"], &(&1["id"] == "llama3"))
      assert model["object"] == "model"
      assert model["owned_by"] == "ollama"
    end

    test "fetches a single model by id, 404s an unknown one" do
      assert get_json("/v1/models/llama3").status == 200
      assert get_json("/v1/models/nope").status == 404
    end

    test "is behind the same bearer gate as chat completions" do
      Application.put_env(:coordinator, :api_token, "secret-key")

      assert get_json("/v1/models").status == 401
      assert get_json("/v1/models", [{"authorization", "Bearer secret-key"}]).status == 200
    end
  end

  # Poll a function until it returns non-nil (the just-created job appears).
  defp wait_for(fun, tries \\ 100)
  defp wait_for(_fun, 0), do: flunk("job never appeared")

  defp wait_for(fun, tries) do
    case safe(fun) do
      nil ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      val ->
        val
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  end
end
