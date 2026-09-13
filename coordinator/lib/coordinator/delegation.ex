defmodule Coordinator.Delegation do
  @moduledoc """
  Submitting work on behalf of a caller, independent of the door they came through.

  The OpenAI front door and the MCP surface disagree about almost everything — one blocks on a
  socket and speaks in chat completions, the other returns an id and speaks in tools — but they
  must agree exactly about privacy resolution, attribution, ownership and routing, because those
  are the guarantees. This module is where that agreement lives.

  It deliberately owns one ordering that is easy to get wrong: a caller who intends to wait for
  a result must subscribe *before* the job is enqueued, or a fast worker can answer into the gap
  between the two and the caller waits out its whole deadline for a result already delivered.
  `submit/1` takes the topics to subscribe as part of submitting, so no caller has to remember.
  """

  alias Coordinator.{ApiAuth, Jobs, Models}

  @privacy_levels Enum.map(Coordinator.Job.privacy_levels(), &to_string/1)

  @default_timeout_ms 1_800_000
  @max_timeout_ms 21_600_000

  @doc """
  Submit a job.

  `:subscribe` names the per-job topics to join before the row exists. Pass `[:result]` to wait
  for the answer, `[:result, :progress]` to also watch it run, or omit it entirely — which is
  what an asynchronous caller does, since it will come back and read the row instead.
  """
  def submit(%{} = request) do
    caller = request.caller
    job_id = Jobs.gen_id()

    Enum.each(Map.get(request, :subscribe, []), fn
      :result -> Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic(job_id))
      :progress -> Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.progress_topic(job_id))
      :chunks -> Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_chunks:" <> job_id)
    end)

    with :ok <- check_model(request),
         :ok <- check_open_jobs(caller) do
      Jobs.submit(%{
        id: job_id,
        capability: capability(),
        privacy: request.privacy.level,
        allow_external_providers: request.privacy.allow_external_providers,
        expires_at: DateTime.add(DateTime.utc_now(), request.timeout_ms, :millisecond),
        payload: request.payload,
        metadata: Map.get(request, :metadata),
        idempotency_key: Map.get(request, :idempotency_key),
        api_token_id: caller.token_id,
        owner_scope: ApiAuth.caller_scope(caller),
        source: Map.get(request, :source, "mcp")
      })
    end
  end

  @doc "Read a job this caller owns."
  def get(job_id, caller), do: Jobs.get_for_caller(job_id, ApiAuth.caller_scope(caller))

  @doc """
  Cancel a job this caller owns.

  Ownership is checked first and a job belonging to someone else is reported as unknown, so an
  agent cannot stop another caller's work — or learn that it exists.
  """
  def cancel(job_id, caller) do
    case get(job_id, caller) do
      nil -> {:error, :unknown_job}
      job -> Jobs.cancel(job.id)
    end
  end

  @doc """
  How long a delegated job may take before the coordinator gives up on it.

  Much longer than the HTTP door's, because nothing is holding a connection open — but bounded,
  and for a reason worth stating: for a worker that cannot renew its lease, `lease_expires_at`
  is pinned to this deadline, so a worker that dies mid-job strands the row until it passes.
  """
  def resolve_timeout(nil), do: @default_timeout_ms

  def resolve_timeout(ms) when is_integer(ms) and ms > 0,
    do: ms |> max(1_000) |> min(@max_timeout_ms)

  def resolve_timeout(_), do: @default_timeout_ms

  def max_timeout_ms, do: @max_timeout_ms
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Resolve a requested privacy level.

  **The default here is `local_only`, where the HTTP door defaults to `public`.** That is
  deliberate and is not an inconsistency: the HTTP door defaults to `public` because every
  caller that existed before privacy levels was pinned to it and must not change meaning. This
  door has no such history, and what arrives through it is delegated work — repository content,
  internal prose — from an agent that did not necessarily think about where it would run.
  """
  def resolve_privacy(level, allow_external \\ nil)

  def resolve_privacy(nil, _), do: {:ok, %{level: "local_only", allow_external_providers: false}}

  def resolve_privacy(level, allow_external) when is_binary(level) do
    cond do
      level not in @privacy_levels ->
        {:error, {:bad_privacy, level}}

      level in ["sensitive", "local_only"] ->
        # A refusal to leave the machine is not negotiable by another argument.
        {:ok, %{level: level, allow_external_providers: false}}

      true ->
        {:ok, %{level: level, allow_external_providers: allow_external == true}}
    end
  end

  def resolve_privacy(level, _), do: {:error, {:bad_privacy, level}}

  defp check_model(%{payload: %{"model" => model}}) when is_binary(model) and model != "" do
    if Models.available?(model), do: :ok, else: {:error, {:model_unavailable, model}}
  end

  defp check_model(_), do: :ok

  # A blocking request was its own backpressure: a caller could only have as many jobs running
  # as it was willing to hold connections open for. Submitting asynchronously removes that, so
  # without a ceiling one agent in a retry loop can fill the queue for every other caller.
  defp check_open_jobs(caller) do
    limit = Application.get_env(:coordinator, :mcp_max_open_jobs_per_key, 32)
    scope = ApiAuth.caller_scope(caller)

    if is_integer(limit) and limit > 0 and Jobs.open_job_count(scope) >= limit do
      {:error, {:too_many_open_jobs, limit}}
    else
      :ok
    end
  end

  defp capability, do: Application.get_env(:coordinator, :api_capability, "chat")
end
