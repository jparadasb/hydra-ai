# hydra-ai — build status

Worker node execution modes (local model + user-provided API provider), per the addendum.
Greenfield → first vertical slice, with the **provider-tokens-stay-on-the-worker** rule
enforced and tested on both sides.

## Tests: 54 passing (33 Rust + 21 Elixir), incl. a live end-to-end

```sh
cd worker && cargo test --workspace     # 33
cd coordinator && mix test              # 21 (one drives the real worker binary over a socket)
```

The Elixir suite starts a live endpoint and the actual `hydra-worker` binary, which connects
over a WebSocket, registers, is leased a job, runs it through the gateway, and returns a
secret-free result the coordinator observes (`test/integration_test.exs`).

## Done

**worker-core (Rust)**
- Execution modes + routing policy + limits + privacy prefs (`config.rs`)
- `ProviderAdapter` trait + `AdapterRegistry` (`adapter.rs`)
- Adapters: OpenAI-compatible (OpenAI/OpenRouter/Groq/Mistral/Together/Fireworks/custom),
  Anthropic, Gemini, Ollama (`adapters/`) — request/response mapping tested via mock HTTP
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

**worker-tauri** — UI command layer (`commands.rs`, `dto.rs`); returns fingerprints only,
tested that the raw token never crosses the boundary.

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

## Remaining

1. **Coordinator durability**: Oban + Ecto/Postgres for durable jobs/leases and re-queue on
   worker rejection/timeout. `WorkerSession` + `Router` + the channel are ready to wrap; the
   live transport is done.
2. **Desktop app shell**: Tauri runtime + `worker/ui/` web frontend over `worker-tauri`
   commands (4 screens: mode chooser, providers, privacy, usage). Command layer done + tested.
3. Broaden local runtimes beyond Ollama (llama.cpp / LM Studio / vLLM) behind the same trait.
