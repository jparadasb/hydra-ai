defmodule Coordinator do
  @moduledoc """
  hydra-ai coordinator: leases jobs to worker nodes and routes them by capability, privacy,
  trust, cost, and policy.

  Core rule: **the coordinator never receives or stores provider tokens.** Workers register
  capabilities + usage only; `Coordinator.SecretGuard` enforces this at the boundary.

  It does, however, store job text: a `jobs` row holds the caller's prompt and the worker's
  completion, which is what makes a job durable and retryable. `Coordinator.JobRetention`
  bounds how long — redacting the text from terminal jobs after a configured window and
  deleting the rows after a longer one.

  Key modules:

    * `Coordinator.SecretGuard`    — strips/rejects secret-shaped payloads (defense in depth)
    * `Coordinator.Job`            — job + privacy levels
    * `Coordinator.Worker`         — a registered worker's non-secret capability snapshot
    * `Coordinator.Router`         — privacy-aware routing + scheduling score
    * `Coordinator.WorkerRegistry` — live in-memory worker set (source of truth for routing)
    * `Coordinator.WorkerSession`  — channel-boundary logic (`Coordinator.WorkerChannel` wraps it)
    * `Coordinator.WorkerChannel`  — per-worker Phoenix Channel (registration in, leases out)
    * `Coordinator.Jobs`           — durable job/lease lifecycle (Ecto + SQLite)
    * `Coordinator.LeaseWorker`    — Oban worker that assigns pending jobs via the Router

  Durability: jobs are persisted (`Coordinator.Repo`, SQLite) and leased by Oban (Lite
  engine), so assignment survives restarts and retries when no worker is yet eligible.
  """

  @doc """
  Submit a job for durable, privacy-aware leasing. `attrs` needs at least `:capability` and
  `:privacy`; optionally `:allow_external_providers` and `:payload`. Returns `{:ok, record}`.
  """
  defdelegate submit_job(attrs), to: Coordinator.Jobs, as: :enqueue
end
