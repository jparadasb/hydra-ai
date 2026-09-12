defmodule Coordinator.WorkerSignals do
  @moduledoc """
  The scheduling signals the coordinator measures for itself, as pure functions.

  Routing used to score workers on numbers the workers reported about themselves: a worker
  could register as `trusted` with `avg_latency_ms: 0` and win essentially every decision
  against honest ones. Trust moved to the admin (`Coordinator.WorkerPolicies`); the rest is
  measured here, from what the coordinator observes at the channel boundary — a job going out
  and its result coming back.

  `Coordinator.WorkerChannel` owns the state these functions fold over, for the same reason it
  owns `inflight`: it is the one process that sees both ends of every lease.
  """

  # Weight of the newest sample. High enough to follow a worker that has genuinely slowed
  # down within a handful of jobs, low enough that one slow generation does not resink it.
  @ewma_alpha 0.3

  # The window `max_requests_per_hour` is actually denominated in.
  @window_ms 3_600_000

  # A failure is worth one point and each subsequent success pays off this fraction of what is
  # left, so a worker that fails once recovers in a few jobs and one that fails constantly
  # stays penalized.
  @failure_recovery 0.5

  # Ignore absurd samples rather than letting one poison the average: a lease can outlive its
  # job's deadline through a reconnect, and the result timestamp is not evidence of throughput.
  @max_credible_latency_ms 600_000

  @doc """
  Fold one observed lease duration into a worker's average latency.

  The first sample seeds the average — starting from the struct default of 0.0 and easing
  toward reality would make every freshly connected worker look like the fastest on the
  network for its first several jobs.
  """
  def observe_latency(current, sample_ms) when sample_ms < 0, do: current
  def observe_latency(current, sample_ms) when sample_ms > @max_credible_latency_ms, do: current
  def observe_latency(current, sample_ms) when current in [nil, 0, 0.0], do: sample_ms / 1

  def observe_latency(current, sample_ms),
    do: @ewma_alpha * sample_ms + (1 - @ewma_alpha) * current

  @doc """
  Add a completion at `now_ms` to the rolling window, dropping anything older than an hour.

  Returns the pruned list. Bounded by how many jobs a worker can actually finish in an hour,
  which is the same thing the window is measuring.
  """
  def record_completion(completions, now_ms) do
    [now_ms | completions] |> Enum.filter(&(now_ms - &1 < @window_ms))
  end

  @doc "How many completions fall inside the trailing hour ending at `now_ms`."
  def requests_in_window(completions, now_ms) do
    Enum.count(completions, &(now_ms - &1 < @window_ms))
  end

  @doc """
  Fold one job outcome into a worker's failure score.

  A rejected result, an error, or a lease that expired without one all count — each is the
  worker failing to do the thing it was given. Anything else pays down the score.
  """
  def record_outcome(failures, outcome) when outcome in [:failed, :rejected, :timeout] do
    failures + 1.0
  end

  def record_outcome(failures, _outcome), do: failures * @failure_recovery

  @doc """
  Classify a result payload's `status` for `record_outcome/2`.

  A missing status is treated as a failure: a worker that answers without saying whether it
  succeeded has not demonstrated that it did.
  """
  def outcome(%{"status" => "ok"}), do: :ok
  def outcome(%{"status" => "rejected"}), do: :rejected
  def outcome(%{"status" => _}), do: :failed
  def outcome(_), do: :failed
end
