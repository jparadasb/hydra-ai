# hydra-ai — build status

Worker node execution modes (local model + user-provided API provider), per the addendum.
Greenfield → first vertical slice, with the **provider-tokens-stay-on-the-worker** rule
enforced and tested on both sides.

## Tests: 45 passing (29 Rust + 16 Elixir)

```sh
cd worker && cargo test --workspace     # 29
cd coordinator && mix test              # 16
```

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

**coordinator (Elixir)**
- `SecretGuard` (strips/rejects secret-shaped payloads), `Job`, `Worker`, `Router`
  (privacy table + scheduling score), `WorkerRegistry` (GenServer + process monitoring),
  `WorkerSession` (channel-boundary logic). All tested.

**proto** — JSON schemas for registration / usage / job / job_result (no secret fields).

## Remaining (transport + shell)

1. **Worker ↔ coordinator transport**: Phoenix Channel client in worker-core
   (`coordinator_client`) joining the socket, sending registration, running leases through
   `Gateway::execute`, returning results. Payloads + gateway + secret guard already done.
2. **Coordinator durability/endpoint**: `WorkerChannel` (Phoenix.Channel) + Oban/Ecto/Postgres
   for durable jobs/leases. `WorkerSession` + `Router` are ready to wrap.
3. **Desktop app shell**: Tauri runtime + `worker/ui/` web frontend over `worker-tauri`
   commands (4 screens: mode chooser, providers, privacy, usage).
4. Broaden local runtimes beyond Ollama (llama.cpp / LM Studio / vLLM) behind the same trait.
