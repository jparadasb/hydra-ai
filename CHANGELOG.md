# Changelog

Notable changes. Worker releases are tagged `v*` and carry generated release notes with
download links; this file is the human summary, and covers the coordinator too — which ships
continuously from `main` and so has no tags of its own to read.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

Nothing yet.

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
