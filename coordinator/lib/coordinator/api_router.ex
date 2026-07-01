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

  match _ do
    error(conn, 404, "unknown endpoint", "invalid_request_error")
  end

  # ---- chat completions ---------------------------------------------------------------------

  defp chat_completion(conn) do
    params = conn.body_params

    # Subscribe BEFORE submitting so a fast worker result can never be broadcast in the window
    # between enqueue and subscribe. `await_result` filters to our job_id, so other jobs'
    # results we receive in the meantime are harmless.
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_results")

    with {:ok, messages} <- fetch_messages(params),
         timeout = resolve_timeout(conn, params),
         payload = build_payload(params, messages),
         {:ok, record} <- submit(payload) do
      case await_result(record.id, timeout) do
        {:ok, %{"status" => "ok"} = result} ->
          json(conn, 200, openai_completion(record.id, params, result))

        {:ok, %{"status" => "rejected", "reason" => reason}} ->
          error(conn, 422, "job rejected: #{reason}", "invalid_request_error")

        {:ok, %{"reason" => reason}} ->
          error(conn, 502, "worker error: #{reason}", "api_error")

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
