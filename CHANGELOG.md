# Changelog

Notable changes. Worker releases are tagged `v*` and carry generated release notes with
download links; this file is the human summary, and covers the coordinator too — which ships
continuously from `main` and so has no tags of its own to read.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

Nothing yet.

## 1.3.0 — 2026-09-14

Hydra gains an agent-facing door. Until now it was an OpenAI-compatible gateway that held one
HTTP request open for a job's entire life — fine for a chat client, a poor fit for an agent
delegating work that runs for minutes on local hardware. `POST /mcp` inverts that: submit, get
an id, disconnect, come back for the answer.

The durable engine underneath is the one that was already there. Jobs were always persisted,
scheduled through Oban, routed on privacy and admin-granted trust, and retried with backoff.
What was missing was the door, and the observability that makes a long job legible while it is
still running.

### Added

- **MCP endpoint** (`POST /mcp`), Streamable HTTP, serving protocol revisions `2026-07-28` and
  `2025-11-25`-and-earlier — clients are split across the revision that removed the `initialize`
  handshake. Authenticated with the same gateway key as `/v1`.
- **Five tools**: `hydra_submit_job`, `hydra_get_job`, `hydra_cancel_job`, `hydra_get_result`,
  `hydra_provide_input`.
- **Native MCP tasks** (`io.modelcontextprotocol/tasks`) for clients that declare it — the same
  job behind a different envelope, never a second implementation.
- **Live progress**: workers report phase, token counts and the model actually in use while a
  job runs, throttled to every 64 tokens or 2s. Persisted, so a caller that disconnected can
  come back and read it. Throughput is computed coordinator-side; a worker still may not say how
  fast it is.
- **`input_required`**: a delegated model can pause, ask its caller for a file or a definition it
  was not given, and resume under the same job id rather than guessing or being handed a whole
  repository up front.
- **Job retrieval over HTTP**: `GET /v1/jobs/:id` and `/v1/jobs/:id/result`, so a client whose
  stream dropped can collect its own work. The response id was already `chatcmpl-<job_id>`, so
  no new correlation is needed.
- **`x-hydra-on-disconnect: detach`** leaves a job running when a streaming client hangs up
  instead of cancelling it. Default stays `cancel`.
- **Ceilings**: per-key monthly token quota, per-job `max_total_tokens`, per-key open-job limit,
  and a result size cap on the worker link (nothing bounded a result before).
- **`model_policy`**: `prefer` orders the choice and `require_local` filters it, for a delegating
  agent that wants "whatever can do this locally" rather than a model name it cannot verify is
  connected.
- **Structured results**: `output.artifacts`, so a job can return a patch and a note alongside
  its answer.
- **Idempotency**: an optional key scoped to the submitting caller. A retried submission returns
  the first job rather than buying a second expensive run.

### Fixed

Five latent bugs, none of which had tests:

- A worker's result for an **already-cancelled job** was persisted and broadcast, because
  `complete/2` returned early before the stale-lease check. Invisible over HTTP — the caller had
  already given up — but `hydra_get_result` would have served it.
- **`hydra.job.duration` measured from `updated_at`**, which the lease heartbeat rewrites every
  20s, so on any job outliving one heartbeat it reported time since the last heartbeat rather
  than the job's duration.
- A **completed job never recorded the worker's authoritative token counts** on its row.
- **`/v1/responses` streamed without `cache-control: no-cache` or `x-accel-buffering: no`**,
  which `/v1/chat/completions` has always sent — so a reverse proxy could accumulate Codex's
  events and deliver them in one lump.
- A job whose **privacy level no connected worker is permitted to take** sat in `routing`
  reporting "choosing a worker" until its deadline, instead of being refused at submission.

### Changed

- Jobs carry a second, finer `state` (`queued` → `routing` → `leased` → `generating` → …)
  alongside `status`. `status` keeps its five values because every compare-and-swap in the job
  lifecycle guards on it.
- Every job now carries an owner. A job is visible only to the key that submitted it, and one
  belonging to another key reads exactly like one that does not exist.
- `Coordinator.Jobs.cancel/1` returns `{:ok, :cancelled | :already_terminal, record}` so a
  caller can tell whether it stopped anything. Internal API; the crates are unpublished.
- Front-door auth, SSE framing and model listing moved out of `api_router.ex` into their own
  modules, so the MCP surface shares one door rather than growing a second copy of it.

### Upgrade notes

- **Update the coordinator before the workers.** A 1.3.0 worker emits `job_progress` (and, when
  enabled, `input_request`) events that a pre-1.3.0 coordinator does not recognize — and an
  unrecognized channel event used to raise, taking the channel down and dropping every job that
  worker was running. 1.3.0 adds a catch-all that refuses the message and keeps the connection,
  so the coordinator must be the one that has it. A deployment that ships the coordinator
  continuously from `main` already does.
- **An older worker keeps working.** Progress and context requests are negotiated by capability
  flags in the registration, so a 1.2.x worker simply reports no progress, and routing will not
  send it a job that may ask for context.
- **Privacy levels are admin-granted and default to public-only.** The MCP door defaults
  submissions to `local_only`, so a fresh deployment refuses them until you grant a worker that
  level in `/admin`. The refusal says so and lists the levels your workers do accept.
- **The MCP endpoint is on by default** and behind the same gateway key as `/v1`.
  `HYDRA_MCP_ENABLED=false` turns it off. A browser `Origin` is refused unless listed in
  `HYDRA_MCP_ALLOWED_ORIGINS`; agent clients send none and are unaffected.
- **Native MCP tasks are advertised but handed out only to clients that declare the extension.**
  Neither Claude Code nor Codex implements it at the time of writing, so the tools are the path
  that runs. `HYDRA_MCP_TASKS_MODE=never` disables task handles without a redeploy.
- New columns are added by migration; no manual step.

## 1.2.0 — 2026-09-13

Everything below landed after 1.1.4. The coordinator ships continuously from `main`, so its
changes were live before this tag; the worker binaries and desktop bundles are this release.

**Upgrading.** No action for workers — `hydra-worker update --restart`, or the desktop app's
update banner. Two things to know if you run a coordinator:

- `DB_ADAPTER` is now **required** in production and must match the adapter the release was
  built against. The published image sets it, so a compose or Kubernetes deployment using that
  image is unaffected; a hand-built release is not.
- A cluster topology (`HYDRA_CLUSTER_SERVICE`) on SQLite is now refused at startup rather than
  silently giving every replica its own database. More than one replica needs Postgres.

`.env.example` now enables worker device auth and the gateway-key requirement by default. That
changes nothing for an existing `.env`; it changes what a new deployment gets by following the
quickstart.

### Security

- **Patched every known advisory in the coordinator's dependency tree** — Phoenix (unlimited
  channel joins per connection, a process-exhaustion DoS aimed squarely at the worker socket),
  Phoenix LiveView (open redirect, XSS via `<.link>`), Mint (three memory-exhaustion DoS), and
  Postgrex. None of these would have been noticed: nothing audited dependencies.
- **`SecretGuard` redacts instead of rejecting.** A completion that merely *talked about* an
  `Authorization` header was dropped whole, and the caller got a 504 with nothing to diagnose.
  Key and value matching also widened considerably — `access_token`, `client_secret`, AWS,
  GitHub, Slack, Stripe, JWTs, PEM blocks, and an entropy check for shapes we do not know.
- **Worker trust is the admin's to grant.** It used to come from the worker's own registration
  and was worth a routing bonus, so a worker could declare itself trusted and win nearly every
  routing decision.
- **The front door has ceilings**: per-key request rate, in-flight concurrency, and request
  body size. One key holder could previously saturate the whole network.
- **Requests carry a privacy level** (`x-hydra-privacy`), and workers enforce the levels they
  advertise. Both halves were missing: callers could not ask for stricter handling, and
  `accepted_job_levels` was advertised but never checked.

### Added

- Metrics at `/metrics` and structured logging on both sides. The worker depended on `tracing`
  and never installed a subscriber, so every log statement in it was a no-op.
- Per-key usage accounting (`usage_records`). Worker usage reports were previously discarded.
- Prompt/completion retention: text redacted after a window, rows deleted after a longer one.
- Streaming on every adapter — Ollama, Anthropic, Gemini and Code Assist had none, and the
  ChatGPT backend buffered its entire SSE body before parsing it.
- Bounded retry with `Retry-After` on 429/503. A single transient failure used to fail a job.
- Nightly Postgres backups, health checks, resource limits, log rotation, a runbook, Dependabot,
  and a dependency-audit workflow.

### Fixed

- Job results are broadcast per-job. Every in-flight request received every other caller's
  completion.
- Enqueue is transactional; `attempts` counts failures rather than lease handoffs; retries back
  off.
- Worker robustness: a provider-supplied index no longer sizes an allocation, buffers are
  bounded, locks survive a panic, the outbound channel is bounded, and the reconnect backoff
  resets only after a connection that stayed up.
- `DB_ADAPTER` must be set explicitly in production, and clustering on SQLite is refused —
  the documented scaling path silently gave every replica its own database.
- The job table is indexed, and the dashboard aggregates in SQL instead of loading a day of
  rows into memory every five seconds.

### Removed

- The OS keychain vault backend. It was documented as available and constructed by nothing:
  the selector had no callers, the feature was off by default, and no shipped binary contained
  it. Every install has always used the encrypted file vault, which is what the docs now say.

## 1.1.4 and earlier

See the [GitHub releases](https://github.com/jparadasb/hydra-ai/releases).
