defmodule Coordinator.Router do
  @moduledoc """
  Privacy-aware job routing. Given a `Coordinator.Job` and the live set of
  `Coordinator.Worker`s, selects an eligible worker (or none).

  Privacy table (worker eligibility):

  | privacy     | eligible workers                                                        |
  |-------------|-------------------------------------------------------------------------|
  | public      | local-model AND external-provider workers                               |
  | private     | external only if the job permits it; otherwise local/org/internal       |
  | sensitive   | NOT external-provider by default (must have a local model)              |
  | local_only  | must NOT use an external provider (must have a local model)             |

  Among eligible workers a scheduling score (lower is better) trades off in-flight load,
  latency, trust, and a penalty for paid external execution so the coordinator avoids
  over-loading paid workers.
  """

  alias Coordinator.{Job, Worker}

  @doc "Pick the best eligible worker, or `{:error, :no_eligible_worker}`."
  @spec route(Job.t(), [Worker.t()]) :: {:ok, Worker.t()} | {:error, :no_eligible_worker}
  def route(%Job{} = job, workers) when is_list(workers) do
    workers
    |> Enum.filter(&eligible?(job, &1))
    |> prefer_requested_model(job)
    |> case do
      [] -> {:error, :no_eligible_worker}
      eligible -> {:ok, Enum.min_by(eligible, &score(job, &1))}
    end
  end

  # A requested model is an exact constraint. Never silently substitute another model.
  #
  # `model_policy` is the other way to ask, and it exists because the two doors want different
  # things. An OpenAI client names a model and means it — substituting one would change what its
  # response says it is. A delegating agent usually wants "whatever can do this, cheaply", and
  # naming a model it cannot verify is available is how a submission 404s for no good reason.
  #
  # A policy narrows and orders; it never widens. `require_local` is a hard filter because it is
  # a refusal to leave the machine in all but name, and `prefer` is a scoring bonus so that an
  # unavailable preference degrades to "something else eligible" rather than to nothing.
  defp prefer_requested_model(eligible, %Job{model: nil} = job) do
    case require_local(job) do
      true -> Enum.filter(eligible, &Worker.has_local?(&1, job.capability))
      _ -> eligible
    end
  end

  defp prefer_requested_model(eligible, %Job{model: model} = job) do
    Enum.filter(eligible, &Worker.serves_model?(&1, job.capability, model))
  end

  defp require_local(%Job{payload: %{"model_policy" => %{"require_local" => true}}}), do: true
  defp require_local(_), do: false

  defp preferred_models(%Job{payload: %{"model_policy" => %{"prefer" => prefer}}})
       when is_list(prefer),
       do: prefer

  defp preferred_models(_), do: []

  @doc "All workers eligible to run `job` (capability + privacy + availability)."
  @spec eligible(Job.t(), [Worker.t()]) :: [Worker.t()]
  def eligible(%Job{} = job, workers), do: Enum.filter(workers, &eligible?(job, &1))

  @doc false
  def eligible?(%Job{} = job, %Worker{} = w) do
    w.available and
      job.privacy in w.accepted_job_levels and
      Worker.serves?(w, job.capability) and
      not over_capacity?(w) and
      privacy_compatible?(job, w) and
      can_request_context?(job, w)
  end

  # A job carrying the reserved `hydra_request_context` tool must go to a worker that knows to
  # pause on it. An older worker would run the tool call straight through and hand the caller a
  # tool call for a tool they never defined — a confusing result rather than a pause.
  defp can_request_context?(%Job{} = job, %Worker{} = w) do
    not context_requests?(job) or Map.get(w, :supports_input_requests, false)
  end

  defp context_requests?(%Job{payload: %{"tools" => tools}}) when is_list(tools) do
    Enum.any?(
      tools,
      &(get_in(&1, ["function", "name"]) == Coordinator.Mcp.ContextRequest.tool_name())
    )
  end

  defp context_requests?(_), do: false

  # The core privacy table.
  defp privacy_compatible?(%Job{privacy: :public}, _w), do: true

  defp privacy_compatible?(%Job{privacy: :private} = job, w) do
    Worker.has_local?(w, job.capability) or
      (job.allow_external_providers and Worker.has_external?(w, job.capability))
  end

  defp privacy_compatible?(%Job{privacy: :sensitive} = job, w),
    do: Worker.has_local?(w, job.capability)

  defp privacy_compatible?(%Job{privacy: :local_only} = job, w),
    do: Worker.has_local?(w, job.capability)

  # Don't hand work to a paid worker already at its declared hourly request ceiling. Compared
  # against completions in the trailing hour, which is what the ceiling is denominated in;
  # this used to compare it against instantaneous `inflight`, a different unit entirely.
  defp over_capacity?(%Worker{max_requests_per_hour: nil}), do: false

  defp over_capacity?(%Worker{requests_last_hour: n, max_requests_per_hour: max}), do: n >= max

  # Lower is better.
  defp score(%Job{} = job, %Worker{} = w) do
    load = w.inflight * 10
    latency = w.avg_latency_ms / 100.0
    trust = trust_bonus(w.trust_level)
    external = if would_use_external?(job, w), do: 50, else: 0
    # Behavioural, and deliberately separate from trust: an admin's grant says what a worker is
    # allowed to be preferred for, while this says what it has actually been doing. A worker
    # that keeps failing loses work without an admin having to intervene, and earns it back by
    # succeeding.
    failures = w.recent_failures * 25
    # Ordered, not filtered: a preference the fleet cannot satisfy right now should cost the job
    # a slower model, not a refusal. Large enough to outrank load and latency, small enough that
    # the external penalty still dominates — a preferred model on an external provider does not
    # beat an unpreferred local one when the job asked to stay local.
    preference = preference_bonus(job, w)
    load + latency + external + trust + failures + preference
  end

  # Each position down the caller's list costs a little. The first preference that a worker can
  # actually serve is the one that counts.
  defp preference_bonus(%Job{} = job, %Worker{} = w) do
    case preferred_models(job) do
      [] ->
        0

      prefer ->
        prefer
        |> Enum.with_index()
        |> Enum.find_value(30, fn {name, index} ->
          if Worker.serves_model?(w, job.capability, name), do: index * 5
        end)
    end
  end

  # Admin-granted (`Coordinator.WorkerPolicies`), not self-declared.
  defp trust_bonus("trusted"), do: -20
  defp trust_bonus("organization"), do: -10
  defp trust_bonus("internal"), do: -15
  defp trust_bonus(_), do: 0

  # The job runs externally on this worker only when there is no local model for it.
  defp would_use_external?(%Job{} = job, %Worker{} = w),
    do: not Worker.has_local?(w, job.capability) and Worker.has_external?(w, job.capability)
end
