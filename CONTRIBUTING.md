# Contributing

Two codebases, each with its own toolchain:

| | |
|---|---|
| `coordinator/` | Elixir / Phoenix. Leases jobs, routes them, serves the OpenAI-compatible front door and `/admin`. |
| `worker/` | Rust. Runs jobs against local runtimes and external providers. Holds the provider tokens. |

## Running the checks

What CI runs, in the order it runs them. Run them before pushing — all of them are fast.

```sh
# Coordinator
cd coordinator
mix deps.get
mix format --check-formatted
mix test

# Worker
cd worker
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# Version agreement across the worker's three manifests
./scripts/check-versions.sh
```

Two things CI checks that are easy to forget locally:

- **`coordinator/priv/site/tailwind.css` is generated but committed.** Edit
  `coordinator/assets/styles.css`, then `npm run build:site`, then commit both.
- **The desktop crate is excluded from the Cargo workspace** (it links webkit2gtk/gtk), so
  `cargo test --workspace` does not touch it. CI builds it separately; see
  `worker/crates/worker-app/SETUP.md` for the system dependencies if you need it locally.

`Coordinator.IntegrationTest` builds and runs the real worker binary, so it needs `cargo` on
`PATH`. It passes in CI.

## The rule the code is built around

**Provider tokens stay on the worker.** The wire contract has no token field, `Secret` is
non-serializable, and `SecretGuard` redacts secret-shaped values at the coordinator boundary.
A change that moves a credential toward the coordinator — into a payload, a log line, or the
database — is wrong regardless of how convenient it is. Tests on both sides assert this.

## Changes

- Branch off `main`; open a PR. CI must pass.
- Say *why* in the commit message, not just what. The diff already says what.
- A behaviour change wants a test that fails without it.
- Comments explain the reason a thing is the way it is, especially when it looks odd. Several
  non-obvious choices in this codebase are load-bearing and commented as such — the privacy
  table, the lease generation checks, the retention windows.

## Reporting a vulnerability

Privately: see [SECURITY.md](SECURITY.md). Not a public issue.

## Licensing

Apache-2.0. Contributions are accepted under the same licence.
