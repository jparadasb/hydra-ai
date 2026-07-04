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
  # While a streaming job runs, emit an SSE keepalive at least this often so an edge proxy
  # (Cloudflare's ~100s idle/TTFB window -> 524) never sees a silent connection. Well under 100s.
  @heartbeat_ms 15_000

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{"status" => "ok"})
  end

  # Public API documentation. `/openapi.json` is an OpenAPI 3.0 spec (import it straight into
  # Postman: Import → Link → https://<host>/openapi.json), `/docs` renders it for humans. Both
  # are unauthenticated so the docs are discoverable without a key.
  get "/openapi.json" do
    json(conn, 200, Coordinator.OpenApi.spec(server_url(conn)))
  end

  get "/docs" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Coordinator.OpenApi.docs_html())
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
      if stream? do
        # Flush headers + a first byte immediately, then heartbeat while the worker runs, so an
        # edge proxy (Cloudflare's ~100s idle/TTFB -> 524) never sees a silent connection during
        # a long generation. Errors after the flush are delivered as SSE, not an HTTP status.
        stream_chat(conn, record.id, params, timeout)
      else
        blocking_chat(conn, record.id, params, timeout)
      end
    else
      {:error, :no_messages} ->
        error(conn, 400, "`messages` must be a non-empty array", "invalid_request_error")

      {:error, {:submit, reason}} ->
        error(conn, 500, "could not enqueue job: #{inspect(reason)}", "api_error")
    end
  end

  # Non-streaming: block until the job result, then map it to one JSON body (or an HTTP error).
  defp blocking_chat(conn, job_id, params, timeout) do
    case await_result(job_id, timeout) do
      {:ok, %{"status" => "ok"} = result} ->
        json(conn, 200, openai_completion(job_id, params, result))

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
      "model" => params["model"],
      "tools" => params["tools"],
      "tool_choice" => params["tool_choice"]
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
    tool_calls = tool_calls(result)
    usage = result["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    model = usage["model"] || params["model"] || "hydra"

    message =
      case tool_calls do
        nil -> %{"role" => "assistant", "content" => content}
        calls -> %{"role" => "assistant", "content" => content, "tool_calls" => calls}
      end

    %{
      "id" => "chatcmpl-" <> job_id,
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => finish_reason(tool_calls)
        }
      ],
      "usage" => %{
        "prompt_tokens" => input,
        "completion_tokens" => output,
        "total_tokens" => input + output
      }
    }
  end

  # Tool calls the worker surfaced in the job output (already OpenAI-shaped), or nil.
  defp tool_calls(result) do
    case get_in(result, ["output", "tool_calls"]) do
      [_ | _] = calls -> calls
      _ -> nil
    end
  end

  defp finish_reason(nil), do: "stop"
  defp finish_reason(_calls), do: "tool_calls"

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

  # Streaming: flush the SSE headers and an assistant `role` delta *before* the worker result
  # exists, keep the connection alive with heartbeats while it runs, then frame the finished
  # result as `chat.completion.chunk`s. The worker returns the full result in one shot (no token
  # streaming end-to-end), so the body is a content delta (plus tool-call deltas when the model
  # requested tools), a finish chunk, an optional usage chunk, then `[DONE]` — what AI-SDK /
  # OpenAI clients (e.g. opencode) expect.
  defp stream_chat(conn, job_id, params, timeout) do
    id = "chatcmpl-" <> job_id
    created = System.system_time(:second)
    model0 = params["model"] || "hydra"

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      # Ask nginx/proxies not to buffer, so chunks flush immediately.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # First byte now (assistant role delta) so the edge proxy sees the stream open immediately.
    conn =
      case chunk(conn, sse(chunk_map(id, created, model0, %{"role" => "assistant"}, nil))) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end

    case await_with_heartbeat(conn, job_id, timeout) do
      {:ok, conn, %{"status" => "ok"} = result} ->
        stream_result_body(conn, id, created, params, result)

      {:ok, conn, %{"reason" => reason}} ->
        stream_error(conn, id, created, model0, "worker error: #{reason}")

      {:ok, conn, _other} ->
        stream_error(conn, id, created, model0, "worker returned no usable output")

      {:timeout, conn} ->
        stream_error(conn, id, created, model0, "no worker completed the job in time")
    end
  end

  # Frame the finished result onto an already-open (chunked) stream, then `[DONE]`.
  defp stream_result_body(conn, id, created, params, result) do
    content = get_in(result, ["output", "content"]) || ""
    tool_calls = tool_calls(result)
    usage = result["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    model = usage["model"] || params["model"] || "hydra"

    # Streaming tool calls carry a per-choice `index` in each delta entry.
    tool_call_deltas =
      case tool_calls do
        nil ->
          []

        calls ->
          calls
          |> Enum.with_index()
          |> Enum.map(fn {call, i} ->
            chunk_map(id, created, model, %{"tool_calls" => [Map.put(call, "index", i)]}, nil)
          end)
      end

    content_deltas =
      if content == "" and tool_calls != nil,
        do: [],
        else: [chunk_map(id, created, model, %{"content" => content}, nil)]

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

    (content_deltas ++
       tool_call_deltas ++
       [chunk_map(id, created, model, %{}, finish_reason(tool_calls)), usage_chunk])
    |> send_events(conn)
  end

  # Once the stream is open we can't set an HTTP error status, so surface the failure as a
  # terminal content delta with `finish_reason: "error"`, then `[DONE]`.
  defp stream_error(conn, id, created, model, message) do
    [
      chunk_map(id, created, model, %{"content" => message}, nil),
      chunk_map(id, created, model, %{}, "error")
    ]
    |> send_events(conn)
  end

  defp chunk_map(id, created, model, delta, finish) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
    }
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  # Encode + write each event, then `[DONE]`. Stops early if the client hung up.
  defp send_events(events, conn) do
    (Enum.map(events, &sse/1) ++ ["data: [DONE]\n\n"])
    |> Enum.reduce_while(conn, fn event, conn ->
      case chunk(conn, event) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # Like `await_result` but writes an SSE keepalive every `@heartbeat_ms` while waiting, and
  # carries the (mutated) conn back so the caller can keep streaming. A failed heartbeat write
  # means the client disconnected -> stop waiting.
  defp await_with_heartbeat(conn, job_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_hb(conn, job_id, deadline)
  end

  # Overridable (tests use a tiny interval); defaults to the module attribute.
  defp heartbeat_ms, do: Application.get_env(:coordinator, :api_heartbeat_ms, @heartbeat_ms)

  defp do_await_hb(conn, job_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, conn}
    else
      wait = min(remaining, heartbeat_ms())

      receive do
        {:job_result, %{"job_id" => ^job_id} = result} -> {:ok, conn, result}
        {:job_result, _other} -> do_await_hb(conn, job_id, deadline)
      after
        wait ->
          case chunk(conn, ": ping\n\n") do
            {:ok, conn} -> do_await_hb(conn, job_id, deadline)
            {:error, _} -> {:timeout, conn}
          end
      end
    end
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

  # Public base URL as the client reached us (honoring the ingress/Cloudflare forwarded proto),
  # so the OpenAPI `servers` entry points back at whatever host was used.
  defp server_url(conn) do
    proto =
      case get_req_header(conn, "x-forwarded-proto") do
        [p | _] -> p
        _ -> to_string(conn.scheme)
      end

    host =
      if conn.port in [80, 443, nil], do: conn.host, else: "#{conn.host}:#{conn.port}"

    "#{proto}://#{host}"
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error(conn, status, message, type) do
    json(conn, status, %{"error" => %{"message" => message, "type" => type}})
  end
end
