defmodule Coordinator.ApiAuth do
  @moduledoc """
  Gateway admission for every authenticated front-door surface: authenticate the caller, charge
  the request against their rate window, and bound how many of their requests run at once.

  Extracted from `Coordinator.ApiRouter` so a second surface (MCP) cannot grow a second,
  subtly different copy of the door. Nothing here renders a response: the OpenAI-compatible
  router wraps a failure in an OpenAI error envelope and MCP wraps it in a JSON-RPC one, so
  every function returns `{:error, status, message, type, headers}` and lets the caller shape it.

  A request is authorized by EITHER the legacy env master key (`:api_token`, constant-time
  compared) OR an admin-issued key from the `api_tokens` table (`Coordinator.ApiTokens`, looked
  up by hash). The door is only *enforced* when a credential is required — i.e. an env master
  key is set, or `:require_api_token` is true (set that in prod so admin-issued keys alone can
  gate the door). Otherwise it stays open for loopback dev.

  Success carries a caller identity rather than a bare `:ok`: `token_id` is the `api_tokens`
  row to attribute jobs and usage to (nil for the env master key and for an open door), and
  `key` is the bucket the rate/concurrency limits count against. An unidentified caller is
  bucketed by peer IP so an open or master-key door is still bounded.
  """
  import Plug.Conn
  require Logger

  @type caller :: %{token_id: String.t() | nil, key: {:token, String.t()} | {:ip, String.t()}}
  @type failure :: {:error, pos_integer(), String.t(), String.t(), [{String.t(), String.t()}]}

  @doc """
  The front door. Authenticate, then charge the request against the caller's rate window.

  Returns `{:ok, caller}` — the identity every downstream artifact is attributed to — or a
  failure tuple for the caller to render.
  """
  @spec admit(Plug.Conn.t()) :: {:ok, caller()} | failure()
  def admit(conn) do
    with {:ok, caller} <- authorize(conn) do
      case Coordinator.RateLimiter.check_rate(caller.key) do
        :ok ->
          {:ok, caller}

        {:error, :rate_limited, retry_after} ->
          Coordinator.Telemetry.emit([:hydra, :api, :rate_limited], %{count: 1}, %{kind: "rate"})

          Logger.info("request rate limited",
            caller: inspect(caller.key),
            retry_after: retry_after
          )

          {:error, 429, "rate limit exceeded, retry in #{retry_after}s", "rate_limit_error",
           [{"retry-after", Integer.to_string(retry_after)}]}
      end
    end
  end

  @doc """
  Run `handler` holding one of the caller's concurrency slots.

  A request that pins a Bandit process, a subscription and a job row for minutes is exactly what
  the cap exists to bound, so the slot covers the whole handler — streaming included — and is
  released even if it raises. (A caller that vanishes mid-stream is covered too: the limiter
  monitors this process.)

  Returns `{:ok, handler_result}` or a failure tuple. Do **not** wrap a poll or a long-lived
  event stream in this: a client polling its own job would exhaust its own budget against itself.
  """
  @spec metered(caller(), (-> term())) :: {:ok, term()} | failure()
  def metered(caller, handler) when is_function(handler, 0) do
    case Coordinator.RateLimiter.acquire(caller.key) do
      :ok ->
        try do
          {:ok, handler.()}
        after
          Coordinator.RateLimiter.release(caller.key)
        end

      {:error, :too_many_concurrent} ->
        Coordinator.Telemetry.emit(
          [:hydra, :api, :rate_limited],
          %{count: 1},
          %{kind: "concurrency"}
        )

        Logger.info("request refused at the concurrency cap", caller: inspect(caller.key))

        {:error, 429, "too many concurrent requests for this key", "rate_limit_error",
         [{"retry-after", "1"}]}
    end
  end

  @doc """
  The caller's ownership and idempotency scope, as a single string.

  A job id used to be known only to whoever submitted it, so a row needed no owner. MCP hands
  job ids to agents, so every read and cancel surface has to filter on something — and the same
  string scopes an idempotency key, so two callers cannot collide on one.
  """
  @spec caller_scope(caller()) :: String.t()
  def caller_scope(%{key: {:token, id}}), do: "tok:" <> id
  def caller_scope(%{key: {:ip, addr}}), do: "ip:" <> addr

  @spec authorize(Plug.Conn.t()) :: {:ok, caller()} | failure()
  def authorize(conn) do
    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    case credential(presented) do
      {:ok, token_id} when is_binary(token_id) ->
        {:ok, %{token_id: token_id, key: {:token, token_id}}}

      {:ok, nil} ->
        {:ok, %{token_id: nil, key: {:ip, peer_ip(conn)}}}

      :error ->
        cond do
          auth_required?() and is_nil(presented) ->
            reject_auth(conn, "missing_token", "missing bearer token")

          auth_required?() ->
            reject_auth(conn, "invalid_key", "invalid api key")

          true ->
            {:ok, %{token_id: nil, key: {:ip, peer_ip(conn)}}}
        end
    end
  end

  # An auth failure was previously silent, so a misconfigured client and an attacker looked
  # identical from outside: both produced nothing. The peer address is logged, never the
  # credential that was presented.
  defp reject_auth(conn, reason, message) do
    Coordinator.Telemetry.emit([:hydra, :api, :auth, :rejected], %{count: 1}, %{reason: reason})

    Logger.warning("front-door auth rejected",
      reason: reason,
      peer_ip: peer_ip(conn),
      path: conn.request_path
    )

    {:error, 401, message, "invalid_request_error", []}
  end

  # `{:ok, token_id}` for an admin-issued key, `{:ok, nil}` for the env master key (valid, but
  # not a row we can attribute to), `:error` for anything else.
  defp credential(nil), do: :error

  defp credential(presented) do
    master = Application.get_env(:coordinator, :api_token)

    if is_binary(master) and master != "" and Plug.Crypto.secure_compare(presented, master) do
      {:ok, nil}
    else
      case Coordinator.ApiTokens.verify(presented) do
        {:ok, token_id} -> {:ok, token_id}
        {:error, :invalid} -> :error
      end
    end
  end

  @doc """
  Peer address as a rate-limit bucket. Behind an ingress this is the proxy unless it sets
  `x-forwarded-for`; the first hop in that header is the client the proxy saw.
  """
  @spec peer_ip(Plug.Conn.t()) :: String.t()
  def peer_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] ->
        value |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc "Whether the door refuses a request that presents no valid credential."
  @spec auth_required?() :: boolean()
  def auth_required? do
    master = Application.get_env(:coordinator, :api_token)

    (is_binary(master) and master != "") or
      Application.get_env(:coordinator, :require_api_token, false)
  end
end
