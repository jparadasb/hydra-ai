# coordinator — hydra-ai coordinator (Elixir)

Routes leased jobs to worker nodes by capability, privacy, trust, cost, and policy. **Never
receives or stores provider tokens** — `Coordinator.SecretGuard` enforces this at the wire
boundary.

## Modules

| module | role |
|--------|------|
| `Coordinator.SecretGuard`    | strips/rejects secret-shaped payloads (defense in depth) |
| `Coordinator.Job`            | job + privacy levels (`public`/`private`/`sensitive`/`local_only`) |
| `Coordinator.Worker`         | a registered worker's non-secret capability snapshot |
| `Coordinator.Router`         | privacy-aware routing + scheduling score |
| `Coordinator.WorkerRegistry` | live in-memory worker set (GenServer; source of truth) |
| `Coordinator.WorkerSession`  | channel-boundary logic (`WorkerChannel` wraps this) |
| `Coordinator.WorkerChannel`  | per-worker Phoenix Channel (registration in, leases out) |
| `Coordinator.Jobs`           | durable job/lease lifecycle (Ecto + SQLite) |
| `Coordinator.LeaseWorker`    | Oban worker that assigns pending jobs via the Router |

## Durability

Jobs are persisted in SQLite (`Coordinator.Repo`) and leased by **Oban** (Lite engine), so
assignment survives restarts. `Coordinator.submit_job/1` enqueues a job; `LeaseWorker` routes
it to an eligible worker (snoozing until one connects), and a worker's result marks the job
`done` or re-queues it (up to 5 attempts) then `failed`. SQLite keeps the coordinator
self-contained — no separate DB server.

## Test

```sh
mix test     # creates + migrates the SQLite test DB, then runs the suite
```

A live integration test launches the real `hydra-worker` binary, which connects over a
WebSocket, registers, is leased a job, and returns a secret-free result.

## Privacy routing table

| privacy     | eligible workers |
|-------------|------------------|
| public      | local-model and external-provider workers |
| private     | external only if the job permits it; otherwise local / org / internal |
| sensitive   | not external-provider by default (must have a local model) |
| local_only  | must not use an external provider |

## Remaining integration (production layer)

* **`WorkerChannel` (Phoenix.Channel)** — persistent worker link; `join`/`handle_in` delegate
  to `Coordinator.WorkerSession`, which already runs `SecretGuard` on every inbound payload.
* **Oban + Ecto/Postgres** — durable job + lease persistence and re-queue on worker
  rejection/timeout. The routing decision (`Coordinator.Router`) is already implemented and
  tested; this adds durability and the transport endpoint.
