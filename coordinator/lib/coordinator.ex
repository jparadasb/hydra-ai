defmodule Coordinator do
  @moduledoc """
  hydra-ai coordinator: leases jobs to worker nodes and routes them by capability, privacy,
  trust, cost, and policy.

  Core rule: **the coordinator never receives or stores provider tokens.** Workers register
  capabilities + usage only; `Coordinator.SecretGuard` enforces this at the boundary.

  Key modules:

    * `Coordinator.SecretGuard`    — strips/rejects secret-shaped payloads (defense in depth)
    * `Coordinator.Job`            — job + privacy levels
    * `Coordinator.Worker`         — a registered worker's non-secret capability snapshot
    * `Coordinator.Router`         — privacy-aware routing + scheduling score
    * `Coordinator.WorkerRegistry` — live in-memory worker set (source of truth for routing)
    * `Coordinator.WorkerSession`  — channel-boundary logic (a Phoenix.Channel wraps this)

  Production transport/persistence (documented, layered on top): a `WorkerChannel`
  (Phoenix.Channel) holds the persistent worker link; Oban + Postgres persist jobs and
  leases. These wrap the pure modules above so the contract stays unit-testable without a DB.
  """
end
