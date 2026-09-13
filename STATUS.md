# hydra-ai — build status

**Snapshot: 2026-09-12.** A status file goes stale the moment it is written; this one had drifted
two and a half months and claimed test counts that were off by half. Treat it as a map of what
exists, not as an inventory — the README is the reference for how to use any of it, and
`git log` is the authority on what changed.

## Tests

```sh
cd worker       && cargo test --workspace     # 126
cd coordinator  && mix test                   # 205
```

The Elixir suite starts a live endpoint and the actual `hydra-worker` binary, which connects
over a WebSocket, registers, is leased a job, runs it through the gateway, and returns a
secret-free result the coordinator observes (`test/integration_test.exs`). That test needs
`cargo` on `PATH`.

## Worker (Rust)

**Adapters** — OpenAI-compatible (OpenAI / OpenRouter / Groq / Mistral / Together / Fireworks /
custom), Anthropic, Gemini (API key and Google sign-in / Code Assist), ChatGPT backend
(OAuth); Ollama, llama.cpp, vLLM, LM Studio locally. All six external paths stream. Every
provider call retries 429/503 with bounded backoff honouring `Retry-After`.

**Token vault** — `Secret` is non-`Serialize` with a redacted `Debug`; an encrypted file store
(ChaCha20-Poly1305 + Argon2id, `0600`) on every platform. There is no keychain backend: one
existed, was unreachable, and was removed.

**Gateway** — job → accepted-privacy-level check → backend selection → limit reserve → adapter
→ usage record → result. Routing preference is a hard constraint, not an ordering. Usage that
a provider did not report is absent rather than reported as zero.

**Runtime** — bounded retry, bounded buffers, locks that survive a panic, a bounded outbound
channel, and a reconnect backoff that resets only after a connection that stayed up.
`tracing` with `HYDRA_LOG` / `HYDRA_LOG_FORMAT`.

**Interfaces** — `worker-cli` (`init`, `provider`, `usage`, `run`, `update`) and a Tauri
desktop app (`worker-app`, excluded from the Cargo workspace because it links system WebView
libraries; CI builds it separately).

## Coordinator (Elixir)

**Front door** — OpenAI-compatible `/v1/chat/completions` (streaming SSE and blocking),
Codex-compatible `/v1/responses`, `/v1/models`, `/health`, `/metrics`, and public
`/openapi.json` + `/docs`. Callers present a gateway key; requests carry a privacy level
(`x-hydra-privacy`) that travels with the job.

**Limits and identity** — every request is attributed to the key that made it; per-key request
rate, in-flight concurrency, and request body size are all bounded.

**Durability** — `jobs` lifecycle (enqueue → lease → done | requeue ×5 → failed) on Ecto +
Oban, with generation-tagged leases, transactional enqueue, and exponential retry backoff.
Prompts and completions are redacted after a window and the rows deleted after a longer one.

**Routing** — privacy table plus a scheduling score over channel-measured latency, in-flight
count, a decaying failure score, and an admin-granted trust level. Nothing a worker says about
itself feeds the score.

**Admin** — `/admin` (GitHub OAuth): issue and revoke gateway keys, grant each worker its
privacy levels and trust, revoke device keys, dashboards.

**Storage** — SQLite (single node) or Postgres (required for more than one replica).
`DB_ADAPTER` is compile-time for the adapter and must be set explicitly in production.

**proto** — JSON schemas for registration / usage / job / job_result. No secret fields, and
the worker refuses a job carrying a field it does not know.

## Known gaps

Tracked as issues rather than listed here, so they cannot go stale:

- **Postgres has never been exercised against a real server.** The adapter, runtime config and
  migrations are in place and the SQLite path runs the whole suite; the Postgres path is
  compile-verified only. See #29.
- **No OS code signing** for the desktop app — Gatekeeper and SmartScreen warn on first run.
  Needs an Apple developer account and a Windows certificate. See `docs/updater-key-rotation.md`.
- **The updater signing key has no second key and no rotation performed** — the procedure is
  written down, but it has not been exercised.
