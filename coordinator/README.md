# coordinator — hydra-ai coordinator (Elixir)

Routes leased jobs to worker nodes by capability, privacy, trust, cost, and policy. **Never
receives or stores provider tokens** — `Coordinator.SecretGuard` enforces this at the wire
boundary.

## Modules

| module | role |
|--------|------|
| `Coordinator.SecretGuard`    | strips/rejects secret-shaped payloads (defense in depth) |
| `Coordinator.Job`            | job + privacy levels (`public`/`private`/`sensitive`/`local_only`) + requested model |
| `Coordinator.Worker`         | a registered worker's non-secret capability snapshot |
| `Coordinator.Router`         | privacy- and model-aware routing + scheduling score |
| `Coordinator.Presence`       | cluster-wide connected-worker set (`Phoenix.Presence` + libcluster) |
| `Coordinator.WorkerRegistry` | reads/writes the worker set via Presence (route/list + track/update) |
| `Coordinator.WorkerPolicies` | admin-granted per-worker privacy levels (on `worker_keys`) |
| `Coordinator.WorkerSession`  | channel-boundary logic (`WorkerChannel` wraps this) |
| `Coordinator.WorkerChannel`  | per-worker Phoenix Channel (registration + presence + leases out) |
| `Coordinator.DeviceAuth`     | Ed25519 trust-on-first-use device-key auth (`worker_keys`) |
| `Coordinator.Jobs`           | durable job/lease lifecycle (Ecto) |
| `Coordinator.LeaseWorker`    | Oban worker that assigns pending jobs via the Router |
| `Coordinator.ApiRouter`      | OpenAI-compatible front-door (`/v1/*`, streaming, `/openapi.json`, `/docs`) |
| `Coordinator.OpenApi`        | OpenAPI 3 spec + Redoc docs page for the public API |
| `Coordinator.Web.*`          | admin console: API keys, workers, dashboard, Oban (GitHub-OAuth gated) |

## Durability

Jobs are persisted (`Coordinator.Repo`) and leased by **Oban**, so assignment survives
restarts. `Coordinator.submit_job/1` enqueues a job; `LeaseWorker` routes it to an eligible
worker (snoozing until one connects), and a worker's result marks the job `done` or re-queues
it (up to 5 attempts) then `failed`.

### Database backend (SQLite ↔ Postgres)

The backend is chosen by the `DB_ADAPTER` env var. The repo adapter is **compile-time**;
connection details + the matching Oban engine/notifier are set at runtime
(`config/runtime.exs`). The `jobs` migration and Oban tables are adapter-agnostic.

| `DB_ADAPTER` | adapter | Oban engine | notifier | use |
|--------------|---------|-------------|----------|-----|
| unset / `sqlite3` | SQLite3 | Lite | PG (process-group) | dev / test / single-node — no DB server |
| `postgres` | Postgres | Basic | Postgres LISTEN/NOTIFY | production / multi-node |

**Production (Postgres):**
```sh
export DB_ADAPTER=postgres                 # MUST be set at build AND boot (adapter is compiled in)
export DATABASE_URL=ecto://user:pass@host/hydra
export SECRET_KEY_BASE=$(mix phx.gen.secret)
MIX_ENV=prod mix release
DB_ADAPTER=postgres DATABASE_URL=... _build/prod/rel/coordinator/bin/coordinator eval "Coordinator.Release.migrate()"
```
Run migrations with the same `DB_ADAPTER`. Everything else (Router, leasing, channel, secret
guard) is unchanged.

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

Which levels a worker may accept is granted by an admin (`Coordinator.WorkerPolicies`,
`/admin/workers`), not declared by the worker. Requested-model routing is layered on top: a
job's `model` restricts eligibility to workers serving that model when any do.

## Public API + admin

`Coordinator.ApiRouter` serves the OpenAI-compatible front-door: `POST /v1/chat/completions`
(with `stream: true` SSE and `tools`/`tool_choice` function calling — `tool_calls` come back
in the message and as indexed stream deltas with `finish_reason: "tool_calls"`),
`GET /v1/models[/{id}]`, `GET /health`, and public docs at
`/openapi.json` (OpenAPI 3 — Postman-importable) + `/docs` (Redoc). The admin console
(`Coordinator.Web.*`, GitHub-OAuth gated in prod) issues gateway API keys and shows
workers/dashboard/Oban. See the root `README.md` for env config and clustering.
