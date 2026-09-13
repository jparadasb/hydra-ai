defmodule Coordinator.MockProvider do
  @moduledoc """
  A minimal OpenAI-compatible provider, for the end-to-end test to point a real worker at.

  The e2e used to lease a capability no worker advertised, so the worker rejected it
  immediately. That exercised the socket round-trip and the secret-free contract, and nothing
  else: no adapter, no completion, no stream, and never the `LeaseWorker` routing path — the
  coordinator's own scheduler was untested end to end.

  This serves just enough for the worker's OpenAI-compatible adapter to treat it as a real
  backend: `GET /v1/models` so the catalog probe finds a model, and
  `POST /v1/chat/completions` blocking or as an SSE stream.

  It also lets the test assert something no mock-free arrangement can: that the **provider
  token the worker holds never reaches the coordinator** while still being presented to the
  provider. The request's `authorization` header is captured here and checked against what the
  coordinator saw.
  """
  use Plug.Router

  @model "mock-model-v1"
  @reply "the mock provider answered"

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @doc "Model name this provider advertises; the job asks for it by name."
  def model, do: @model

  @doc "What a completion from it says."
  def reply, do: @reply

  @doc """
  Start the provider on a free port. Returns `{:ok, base_url}`; the server stops with the
  test process that started it.
  """
  def start_link do
    # Port 0: let the OS pick, so concurrent runs and a developer's own services never collide.
    case Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1}) do
      {:ok, pid} ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        {:ok, pid, "http://127.0.0.1:#{port}/v1"}

      error ->
        error
    end
  end

  @doc """
  The `authorization` header of the last completion request, or nil.

  Stored in `:persistent_term` because the request runs in Bandit's own process, not the
  test's.
  """
  def last_authorization, do: :persistent_term.get({__MODULE__, :auth}, nil)

  def reset, do: :persistent_term.erase({__MODULE__, :auth})

  get "/v1/models" do
    json(conn, %{
      "object" => "list",
      "data" => [%{"id" => @model, "object" => "model"}]
    })
  end

  post "/v1/chat/completions" do
    case get_req_header(conn, "authorization") do
      [value | _] -> :persistent_term.put({__MODULE__, :auth}, value)
      [] -> :ok
    end

    if conn.body_params["stream"] == true do
      stream_completion(conn)
    else
      json(conn, %{
        "id" => "chatcmpl-mock",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => @reply},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
      })
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Deliberately several chunks: a single-chunk "stream" would pass even if the worker
  # buffered the whole body, which is the bug this is meant to be able to catch.
  defp stream_completion(conn) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    conn =
      Enum.reduce(String.split(@reply, " "), conn, fn word, acc ->
        frame =
          Jason.encode!(%{
            "choices" => [%{"index" => 0, "delta" => %{"content" => word <> " "}}]
          })

        {:ok, acc} = chunk(acc, "data: #{frame}\n\n")
        acc
      end)

    usage =
      Jason.encode!(%{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5}
      })

    {:ok, conn} = chunk(conn, "data: #{usage}\n\n")
    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
