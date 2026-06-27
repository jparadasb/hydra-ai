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
| `Coordinator.WorkerSession`  | channel-boundary logic (a Phoenix.Channel wraps this) |

## Test

```sh
mix test
```

Runs without a database — the contract modules are pure / in-memory.

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
