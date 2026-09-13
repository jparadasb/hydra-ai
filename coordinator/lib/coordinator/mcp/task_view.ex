defmodule Coordinator.Mcp.TaskView do
  @moduledoc """
  One job, rendered for an agent.

  Every MCP surface resolves to this: the `hydra_*` tools today, and the native tasks extension
  when a client supports it. Keeping the projection in one place is what makes "both paths, one
  implementation" true rather than aspirational — the two differ only in the envelope the
  transport wraps around this map.

  Pure, and deliberately ignorant of JSON-RPC.
  """

  alias Coordinator.Jobs
  alias Coordinator.Jobs.{JobRecord, State}

  # Namespaced so Hydra's execution detail cannot collide with a field the protocol adds later.
  # The issue sketched a bare `hydra` key; this is the same thing, spelled so it stays valid.
  @meta_key "ai.hydra/job"

  def meta_key, do: @meta_key

  @doc """
  The canonical view of a job.

  `status` is one of the five values MCP defines; everything finer lives under `@meta_key`,
  because overloading the protocol's status field is how a client ends up parsing strings it
  was never promised.
  """
  def render(%JobRecord{} = job) do
    progress = Jobs.progress_view(job)

    %{
      "taskId" => job.id,
      "status" => State.mcp_status(job.state),
      "statusMessage" => status_message(job, progress),
      "createdAt" => iso8601(job.inserted_at),
      "lastUpdatedAt" => iso8601(job.updated_at),
      "pollIntervalMs" => poll_interval_ms(job),
      "ttlMs" => ttl_ms(),
      "_meta" => %{@meta_key => hydra_meta(job, progress)}
    }
  end

  @doc """
  Hydra's own account of the job: the execution detail MCP has no field for.
  """
  def hydra_meta(%JobRecord{} = job, progress \\ nil) do
    progress = progress || Jobs.progress_view(job)

    %{
      "state" => job.state,
      "worker" => job.worker_id,
      "requested_model" => progress.requested_model,
      "model" => progress.actual_model,
      "provider" => progress.provider,
      "privacy" => job.privacy,
      "attempts" => job.attempts,
      "failure_reason" => job.failure_reason,
      "tokens" => %{
        "input" => job.input_tokens,
        "generated" => job.output_tokens
      },
      "performance" => %{
        "tokens_per_second" => progress.tokens_per_second,
        "elapsed_seconds" => progress.elapsed_seconds,
        "queue_seconds" => progress.queue_seconds
      },
      "last_progress_at" => iso8601(job.last_progress_at)
    }
  end

  @doc """
  Whether a finished job finished badly.

  A job that exhausted its attempts against a provider returning 429 produced a perfectly
  well-formed answer — "this did not work" — so it is a completed call carrying an error, not a
  protocol-level failure. See `Coordinator.Jobs.State.mcp_status/1`.
  """
  def error?(%JobRecord{status: status}), do: status in ["failed", "cancelled"]

  @doc """
  The result a caller gets back from a finished job.

  A redacted job answers rather than 404s: the row is still the truth about what happened, and
  a caller asking about a job whose text has expired deserves to be told that, not that their
  job never existed.
  """
  def result(%JobRecord{} = job) do
    base = %{
      "job_id" => job.id,
      "status" => State.mcp_status(job.state),
      "state" => job.state,
      "usage" => usage(job),
      "failure_reason" => job.failure_reason
    }

    cond do
      not State.terminal?(job.state) ->
        Map.merge(base, %{"text" => nil, "artifacts" => [], "redacted" => false})

      is_nil(job.redacted_at) ->
        output = (job.result || %{})["output"] || %{}

        Map.merge(base, %{
          "text" => output["content"],
          "artifacts" => output["artifacts"] || [],
          "tool_calls" => output["tool_calls"],
          "redacted" => false
        })

      true ->
        Map.merge(base, %{
          "text" => nil,
          "artifacts" => [],
          "redacted" => true
        })
    end
  end

  defp usage(%JobRecord{} = job) do
    %{
      "input_tokens" => job.input_tokens,
      "output_tokens" => job.output_tokens,
      "total_tokens" => total(job.input_tokens, job.output_tokens)
    }
  end

  defp total(nil, nil), do: nil
  defp total(a, b), do: (a || 0) + (b || 0)

  # The one line a model reads without parsing metadata, so it says the thing a delegating agent
  # needs in order to decide whether to keep waiting.
  defp status_message(%JobRecord{} = job, progress) do
    case job.state do
      "queued" when job.attempts > 0 ->
        "retrying (attempt #{job.attempts + 1}) — waiting for an eligible worker"

      "queued" ->
        "queued — waiting for an eligible worker"

      "routing" ->
        "choosing a worker"

      "leased" ->
        "assigned to #{job.worker_id}"

      "loading_model" ->
        "#{job.worker_id} is loading #{progress.actual_model || progress.requested_model}"

      "prefill" ->
        "reading the prompt"

      "generating" ->
        generating_message(job, progress)

      "finalizing" ->
        "finishing up"

      "completed" ->
        "completed"

      "cancelled" ->
        "cancelled"

      state when state in ["failed", "expired"] ->
        "failed: #{job.failure_reason || "unknown"}"
    end
  end

  defp generating_message(_job, %{output_tokens: nil}), do: "generating"

  defp generating_message(_job, %{output_tokens: tokens, tokens_per_second: nil}),
    do: "generating — #{tokens} tokens so far"

  defp generating_message(_job, %{output_tokens: tokens, tokens_per_second: rate}),
    do: "generating — #{tokens} tokens so far, #{rate}/s"

  # Poll fast while the answer could arrive at any moment, slowly once it is clear this will
  # take a while. It is also the rate-limit steering mechanism: the only thing telling a
  # polling agent how often to come back.
  defp poll_interval_ms(%JobRecord{state: state}) when state in ["queued", "routing", "leased"],
    do: 2_000

  defp poll_interval_ms(%JobRecord{state: state}) when state in ["loading_model", "prefill"],
    do: 3_000

  defp poll_interval_ms(%JobRecord{}), do: 5_000

  # How long the answer remains readable. Derived from the retention window rather than
  # invented: a made-up ttl produces a client politely polling a job whose text was redacted
  # out from under it.
  defp ttl_ms do
    hours = Application.get_env(:coordinator, :job_redact_after_hours, 24)

    case hours do
      h when is_integer(h) and h > 0 -> h * 3_600_000
      _ -> nil
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
