defmodule Coordinator.ApiRouter do
  @moduledoc """
  The coordinator's public HTTP front-door. Mounted on `Coordinator.Endpoint` alongside the
  worker socket.

  It exposes an **OpenAI-compatible** chat endpoint: a client calls `POST /v1/chat/completions`
  exactly as it would call OpenAI, and the coordinator turns the request into a durable `chat`
  job, routes it to an eligible worker (privacy-aware, via `Coordinator.Router`/Oban), waits for
  the worker's normalized result, and maps it back into the OpenAI response shape.

  This keeps the core rule intact: **no provider token ever transits the coordinator.** The
  caller authenticates to the coordinator with a *gateway* key (`HYDRA_API_TOKEN`), never a
  provider secret; the worker holds its own provider tokens locally and only reports usage.

  Synchronicity: the request blocks until the job's `"result"` arrives on the `"job_results"`
  PubSub topic (the same topic `Coordinator.WorkerSession.handle_result/1` broadcasts on), or
  until a timeout. Override the wait with an `x-hydra-timeout-ms` header or a `timeout_ms` body
  field (handy for load tests when no worker is connected).
  """
  use Plug.Router
  require Logger

  @default_timeout_ms 60_000
  @max_timeout_ms 600_000

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{"status" => "ok"})
  end

  post "/v1/chat/completions" do
    case authorize(conn) do
      :ok -> chat_completion(conn)
      {:error, code, msg} -> error(conn, code, msg, "invalid_request_error")
    end
  end

  get "/v1/models" do
    case authorize(conn) do
      :ok -> json(conn, 200, %{"object" => "list", "data" => list_models()})
      {:error, code, msg} -> error(conn, code, msg, "invalid_request_error")
    end
  end

  get "/v1/models/:id" do
    case authorize(conn) do
      :ok ->
        case Enum.find(list_models(), &(&1["id"] == id)) do
          nil -> error(conn, 404, "model '#{id}' not found", "invalid_request_error")
          model -> json(conn, 200, model)
        end

      {:error, code, msg} ->
        error(conn, code, msg, "invalid_request_error")
    end
  end

  match _ do
    error(conn, 404, "unknown endpoint", "invalid_request_error")
  end

  # ---- models -------------------------------------------------------------------------------

  # OpenAI-shaped model list, aggregated from the live worker registry: every model a connected
  # worker advertises for the front-door's routing capability, deduped by name (first worker
  # wins for `owned_by`). Reflects what a chat completion can actually be served by right now.
  defp list_models do
    capability = Application.get_env(:coordinator, :api_capability, "chat")
    created = System.system_time(:second)

    Coordinator.WorkerRegistry.list()
    |> Enum.flat_map(fn worker ->
      worker.models
      |> Enum.filter(&(capability in &1.capabilities))
      |> Enum.map(fn model ->
        %{
          "id" => model.name,
          "object" => "model",
          "created" => created,
          "owned_by" => worker.provider_name || "hydra"
        }
      end)
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  # ---- chat completions ---------------------------------------------------------------------

  defp chat_completion(conn) do
    params = conn.body_params

    # Subscribe BEFORE submitting so a fast worker result can never be broadcast in the window
    # between enqueue and subscribe. `await_result` filters to our job_id, so other jobs'
    # results we receive in the meantime are harmless.
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_results")

    stream? = params["stream"] in [true, "true"]

    with {:ok, messages} <- fetch_messages(params),
         timeout = resolve_timeout(conn, params),
         payload = build_payload(params, messages),
         {:ok, record} <- submit(payload) do
      case await_result(record.id, timeout) do
        {:ok, %{"status" => "ok"} = result} when stream? ->
          stream_completion(conn, record.id, params, result)

        {:ok, %{"status" => "ok"} = result} ->
          json(conn, 200, openai_completion(record.id, params, result))

        {:ok, %{"status" => "rejected", "reason" => reason}} ->
          error(conn, 422, "job rejected: #{reason}", "invalid_request_error")

        {:ok, %{"reason" => reason}} ->
          {status, type} = classify_worker_error(reason)
          error(conn, status, "worker error: #{reason}", type)

        {:ok, _} ->
          error(conn, 502, "worker returned no usable output", "api_error")

        {:error, :timeout} ->
          error(conn, 504, "no worker completed the job in time", "timeout")
      end
    else
      {:error, :no_messages} ->
        error(conn, 400, "`messages` must be a non-empty array", "invalid_request_error")

      {:error, {:submit, reason}} ->
        error(conn, 500, "could not enqueue job: #{inspect(reason)}", "api_error")
    end
  end

  defp fetch_messages(%{"messages" => [_ | _] = msgs}), do: {:ok, msgs}
  defp fetch_messages(_), do: {:error, :no_messages}

  # Job payload mirrors what the worker's gateway parses (`{messages, max_tokens, ...}`). We
  # pass through the OpenAI knobs the adapters understand; unknown fields are harmless.
  defp build_payload(params, messages) do
    %{
      "messages" => messages,
      "max_tokens" => params["max_tokens"],
      "temperature" => params["temperature"],
      "model" => params["model"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Privacy defaults to public + external allowed so any eligible worker (local or provider) can
  # take it. A future revision can map an `x-hydra-privacy` header here.
  #
  # The routing capability is configurable (`HYDRA_API_CAPABILITY`): the worker runs a chat
  # completion for whatever capability it is asked to serve, so this just has to match a string
  # the connected workers advertise (e.g. "text.extract_json"). Defaults to "chat".
  defp submit(payload) do
    capability = Application.get_env(:coordinator, :api_capability, "chat")

    case Coordinator.submit_job(%{
           capability: capability,
           privacy: "public",
           allow_external_providers: true,
           payload: payload
         }) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, {:submit, reason}}
    end
  end

  # Wait for *this* job's result on the shared topic, ignoring other jobs' results, honoring a
  # hard deadline so a flood of unrelated results can't extend our wait.
  defp await_result(job_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(job_id, deadline)
  end

  defp do_await(job_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:job_result, %{"job_id" => ^job_id} = result} -> {:ok, result}
        {:job_result, _other} -> do_await(job_id, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  # ---- OpenAI response mapping --------------------------------------------------------------

  defp openai_completion(job_id, params, result) do
    content = get_in(result, ["output", "content"]) || ""
    usage = result["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    model = usage["model"] || params["model"] || "hydra"

    %{
      "id" => "chatcmpl-" <> job_id,
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => input,
        "completion_tokens" => output,
        "total_tokens" => input + output
      }
    }
  end

  # Map a worker error into an HTTP status + OpenAI error type. When the worker reports an
  # upstream provider status (e.g. `provider returned status 429`), pass that through so
  # clients see the real cause (rate limit, bad request) instead of a generic 502 — and so an
  # edge proxy like Cloudflare, which masks 5xx bodies with its own error page, doesn't hide
  # it. Upstream 5xx collapse to 502 (bad gateway); anything unrecognized stays 502.
  defp classify_worker_error(reason) do
    case Regex.run(~r/status (\d{3})/, to_string(reason)) do
      [_, code] ->
        case String.to_integer(code) do
          429 -> {429, "rate_limit_error"}
          c when c in 400..499 -> {c, "invalid_request_error"}
          _ -> {502, "api_error"}
        end

      _ ->
        {502, "api_error"}
    end
  end

  # ---- OpenAI streaming (SSE) ---------------------------------------------------------------

  # Emit the completion as an OpenAI `chat.completion.chunk` SSE stream. The worker returns the
  # full result in one shot (no token streaming end-to-end), so we frame it as a role delta, a
  # single content delta, a finish chunk, an optional usage chunk, then `[DONE]`. This is what
  # AI-SDK / OpenAI streaming clients (e.g. opencode) require: without it they wait on a stream
  # that never arrives and end up with an empty message.
  defp stream_completion(conn, job_id, params, result) do
    content = get_in(result, ["output", "content"]) || ""
    usage = result["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    model = usage["model"] || params["model"] || "hydra"
    id = "chatcmpl-" <> job_id
    created = System.system_time(:second)

    chunk_map = fn delta, finish ->
      %{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => created,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
      }
    end

    usage_chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [],
      "usage" => %{
        "prompt_tokens" => input,
        "completion_tokens" => output,
        "total_tokens" => input + output
      }
    }

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      # Ask nginx/proxies not to buffer, so chunks flush immediately (also avoids the proxy
      # closing an idle-looking connection during a long generation).
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    events =
      [
        chunk_map.(%{"role" => "assistant"}, nil),
        chunk_map.(%{"content" => content}, nil),
        chunk_map.(%{}, "stop"),
        usage_chunk
      ]
      |> Enum.map(&("data: " <> Jason.encode!(&1) <> "\n\n"))

    Enum.reduce_while(events ++ ["data: [DONE]\n\n"], conn, fn event, conn ->
      case chunk(conn, event) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # ---- auth + helpers -----------------------------------------------------------------------

  # Gateway access control. A request is authorized by EITHER the legacy env master key
  # (`:api_token`, constant-time compared) OR an admin-issued key from the `api_tokens` table
  # (`Coordinator.ApiTokens`, looked up by hash). The door is only *enforced* when a credential
  # is required — i.e. an env master key is set, or `:require_api_token` is true (set that in
  # prod so admin-issued keys alone can gate the door). Otherwise it stays open for loopback dev.
  defp authorize(conn) do
    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    cond do
      valid_credential?(presented) -> :ok
      auth_required?() and is_nil(presented) -> {:error, 401, "missing bearer token"}
      auth_required?() -> {:error, 401, "invalid api key"}
      true -> :ok
    end
  end

  defp valid_credential?(nil), do: false

  defp valid_credential?(presented) do
    master = Application.get_env(:coordinator, :api_token)

    (is_binary(master) and master != "" and Plug.Crypto.secure_compare(presented, master)) or
      Coordinator.ApiTokens.verify(presented) == :ok
  end

  defp auth_required? do
    master = Application.get_env(:coordinator, :api_token)
    (is_binary(master) and master != "") or Application.get_env(:coordinator, :require_api_token, false)
  end

  defp resolve_timeout(conn, params) do
    from_header =
      case get_req_header(conn, "x-hydra-timeout-ms") do
        [v | _] -> parse_int(v)
        _ -> nil
      end

    (from_header || parse_int(params["timeout_ms"]) || @default_timeout_ms)
    |> max(1)
    |> min(@max_timeout_ms)
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(n) when is_binary(n), do: with({i, _} <- Integer.parse(n), do: i, else: (_ -> nil))
  defp parse_int(_), do: nil

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error(conn, status, message, type) do
    json(conn, status, %{"error" => %{"message" => message, "type" => type}})
  end
end
