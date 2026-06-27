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
    |> case do
      [] -> {:error, :no_eligible_worker}
      eligible -> {:ok, Enum.min_by(eligible, &score(job, &1))}
    end
  end

  @doc "All workers eligible to run `job` (capability + privacy + availability)."
  @spec eligible(Job.t(), [Worker.t()]) :: [Worker.t()]
  def eligible(%Job{} = job, workers), do: Enum.filter(workers, &eligible?(job, &1))

  @doc false
  def eligible?(%Job{} = job, %Worker{} = w) do
    w.available and
      job.privacy in w.accepted_job_levels and
      Worker.serves?(w, job.capability) and
      not over_capacity?(w) and
      privacy_compatible?(job, w)
  end

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

  # Don't hand work to a paid worker already at its declared hourly request ceiling.
  defp over_capacity?(%Worker{max_requests_per_hour: nil}), do: false
  defp over_capacity?(%Worker{inflight: n, max_requests_per_hour: max}), do: n >= max

  # Lower is better.
  defp score(%Job{} = job, %Worker{} = w) do
    load = w.inflight * 10
    latency = w.avg_latency_ms / 100.0
    trust = trust_bonus(w.trust_level)
    external = if would_use_external?(job, w), do: 50, else: 0
    load + latency + external + trust
  end

  defp trust_bonus("trusted"), do: -20
  defp trust_bonus("organization"), do: -10
  defp trust_bonus("internal"), do: -15
  defp trust_bonus(_), do: 0

  # The job runs externally on this worker only when there is no local model for it.
  defp would_use_external?(%Job{} = job, %Worker{} = w),
    do: not Worker.has_local?(w, job.capability) and Worker.has_external?(w, job.capability)
end
