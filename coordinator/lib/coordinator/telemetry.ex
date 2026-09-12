defmodule Coordinator.Telemetry do
  @moduledoc """
  Metrics definitions and the reporter that serves them.

  Nothing here was instrumented before: every failure mode the coordinator has — a wedged
  worker, a stuck lease, a rejected result, an auth failure — was invisible while it happened.
  These are the numbers that make each of them visible from outside the process.

  Scraped at `GET /metrics` in Prometheus text format (`Coordinator.ApiRouter`). The endpoint
  is not part of the public API: it is bound to the same port for simplicity, and an ingress
  should not route it publicly.

  Emitting a measurement is `:telemetry.execute/3` at the site that knows the fact; see
  `Coordinator.Jobs` and `Coordinator.ApiRouter`.
  """
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics()},
      # VM-level numbers nobody emits explicitly: memory, run queues, process count.
      {:telemetry_poller, measurements: [], period: :timer.seconds(10)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Everything the coordinator exposes. Read by the reporter and by the tests."
  def metrics do
    [
      # ---- front door -------------------------------------------------------------------
      counter("hydra.api.request.count",
        tags: [:endpoint, :status],
        description: "Front-door requests by endpoint and HTTP status class"
      ),
      counter("hydra.api.auth.rejected.count",
        tags: [:reason],
        description: "Requests refused at the door: missing or invalid credentials"
      ),
      counter("hydra.api.rate_limited.count",
        tags: [:kind],
        description: "Requests refused by the rate window or the concurrency cap"
      ),

      # ---- job lifecycle ----------------------------------------------------------------
      counter("hydra.job.enqueued.count",
        description: "Jobs accepted and persisted"
      ),
      counter("hydra.job.leased.count",
        description: "Jobs handed to a worker"
      ),
      counter("hydra.job.completed.count",
        tags: [:status],
        description: "Jobs reaching a terminal state, by outcome"
      ),
      counter("hydra.job.requeued.count",
        description: "Failed attempts returned to the queue"
      ),
      counter("hydra.lease.reclaimed.count",
        tags: [:outcome],
        description: "Leases taken back after expiry — the abandoned-worker signal"
      ),
      distribution("hydra.job.duration.millisecond",
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 15_000, 60_000, 300_000]],
        description: "Lease to terminal result"
      ),

      # ---- workers ----------------------------------------------------------------------
      last_value("hydra.workers.connected",
        description: "Workers currently in the cluster-wide registry"
      ),

      # ---- guard ------------------------------------------------------------------------
      counter("hydra.secret_guard.redacted.count",
        description: "Secret-shaped values redacted from worker payloads"
      ),

      # ---- vm ---------------------------------------------------------------------------
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end

  @doc """
  The current metrics, in Prometheus text format.

  Worker count is sampled here rather than pushed: it is a property of the live registry, and
  the registry has no event to hang a counter off.
  """
  def scrape do
    :telemetry.execute([:hydra, :workers], %{connected: length(Coordinator.WorkerRegistry.list())})

    TelemetryMetricsPrometheus.Core.scrape()
  end

  @doc "Record a measurement. A thin wrapper so call sites read as one line."
  def emit(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end
end
