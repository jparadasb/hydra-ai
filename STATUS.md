# hydra-ai — build status

Worker node execution modes (local model + user-provided API provider), per the addendum.
Greenfield → first vertical slice, with the **provider-tokens-stay-on-the-worker** rule
enforced and tested on both sides.

## Tests: 62 passing (36 Rust + 26 Elixir), incl. a live end-to-end

```sh
cd worker && cargo test --workspace     # 36
cd coordinator && mix test              # 26 (one drives the real worker binary over a socket)
```

The Elixir suite starts a live endpoint and the actual `hydra-worker` binary, which connects
over a WebSocket, registers, is leased a job, runs it through the gateway, and returns a
secret-free result the coordinator observes (`test/integration_test.exs`).

## Done

**worker-core (Rust)**
- Execution modes + routing policy + limits + privacy prefs (`config.rs`)
- `ProviderAdapter` trait + `AdapterRegistry` (`adapter.rs`)
- Adapters: OpenAI-compatible (OpenAI/OpenRouter/Groq/Mistral/Together/Fireworks/custom),
  Anthropic, Gemini (external); Ollama + llama.cpp + vLLM + LM Studio (local, `uses_external=false`) —
  request/response mapping tested via mock HTTP; OpenAI-compat HTTP path shared external/local
- Token vault: `Secret` (non-`Serialize`, redacted Debug), encrypted-file store
  (ChaCha20-Poly1305 + Argon2id, `0600`), OS-keychain backend behind `os-keychain` feature,
  `fingerprint`/`redact` (`vault.rs`)
- Privacy enforcement matrix (`privacy.rs`); usage tracking (`usage.rs`); spend/rate limit
  guard (`limits.rs`); hardware detect + benchmark (`runtime.rs`)
- **Gateway** (`gateway.rs`): job → privacy check → limit reserve → adapter → usage record →
  result; secret-free result asserted in tests
- Registration payload builder (`registration.rs`) — secret-free by construction + test

**worker-cli** — `init` / `provider add|test|rm|rotate` / `usage` / `run`. Verified live:
vault file is `0600` and encrypted (token absent from disk, config, and registration).

**worker-tauri** — UI command layer (`commands.rs`, `dto.rs`, `support.rs`); returns
fingerprints only, tested that the raw token never crosses the boundary.

**Desktop app** — `worker/crates/worker-app` (Tauri 2, excluded from the workspace because it
links system WebView libs) + `worker/ui/` frontend (4 screens: mode / providers / privacy /
usage, with a vault-unlock gate). Thin `#[tauri::command]` shell over `worker-tauri`. Build
with `cargo tauri dev` after the system deps in `worker/crates/worker-app/SETUP.md`.

**Transport (worker ↔ coordinator)**
- worker-core `coordinator_client`: Phoenix v2 wire framing (unit-tested) + networked client
  (feature `transport`) that joins `worker:<id>`, sends registration, receives `"job"` leases,
  runs `Gateway::execute`, replies with `"result"`, heartbeats
- coordinator `Endpoint` + `WorkerSocket` + `WorkerChannel` (wraps `WorkerSession`; SecretGuard
  on join + every inbound message); `lease/2` broadcasts a job to a worker topic
- `hydra-worker run` wires config + vault → adapters → gateway → live connection

**coordinator (Elixir)**
- `SecretGuard` (strips/rejects secret-shaped payloads), `Job`, `Worker`, `Router`
  (privacy table + scheduling score), `WorkerRegistry` (GenServer + process monitoring),
  `WorkerSession` (channel-boundary logic). All tested.

**proto** — JSON schemas for registration / usage / job / job_result (no secret fields).

**Durability (Elixir)**
- `Coordinator.Repo` (Ecto + SQLite — no DB server needed), `jobs` table + migration
- `Coordinator.Jobs` lifecycle: enqueue → lease → done | (re-queue ×5) → failed
- `Coordinator.LeaseWorker` (Oban Lite engine): routes pending jobs via the Router, snoozes
  until an eligible worker connects; worker results persist via `WorkerSession`
- `Coordinator.submit_job/1` public entrypoint

## Remaining

1. **Desktop app**: build/verify on a machine with the WebView system deps (this dev box
   lacks webkit2gtk); generate bundle icons. Code + frontend are complete and wired.
2. Production swap: SQLite → Postgres is a repo-adapter + Oban-engine change (Lite → Basic).
