# Changelog

Notable changes. Worker releases are tagged `v*` and carry generated release notes with
download links; this file is the human summary, and covers the coordinator too — which ships
continuously from `main` and so has no tags of its own to read.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

Started at 1.1.4. Everything below landed after that tag and is unreleased on the worker side;
the coordinator changes are live once merged.

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

- The OS keychain vault backend. It was documented as available and constructed by nothing.

## 1.1.4 and earlier

See the [GitHub releases](https://github.com/jparadasb/hydra-ai/releases).
