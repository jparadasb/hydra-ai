//! Log setup for the worker binaries.
//!
//! The crate depended on `tracing` and never installed a subscriber, so every `tracing::` call
//! in it was a no-op — including the ones whose comments said "log for headless workers". The
//! diagnostics that did appear were `eprintln!`, which cannot be filtered, cannot be
//! structured, and cannot be shipped anywhere.
//!
//! Two formats:
//!
//!   * **text** (default) — for a person watching a terminal.
//!   * **json** (`HYDRA_LOG_FORMAT=json`) — one object per line, for a log collector. This is
//!     what a headless worker in a container should run with.
//!
//! `HYDRA_LOG` takes an `EnvFilter` directive (`info`, `warn`, `worker_core=debug`, …) and
//! defaults to `info`.

use tracing_subscriber::EnvFilter;

/// Install the global subscriber. Idempotent by nature — a second call is a no-op rather than
/// a panic, because a library that kills the process over its logging setup is worse than one
/// that logs twice.
pub fn init() {
    let filter = EnvFilter::try_from_env("HYDRA_LOG")
        .or_else(|_| EnvFilter::try_new("info"))
        .unwrap_or_default();

    let json = std::env::var("HYDRA_LOG_FORMAT")
        .map(|v| v.eq_ignore_ascii_case("json"))
        .unwrap_or(false);

    // Logs go to stderr so a CLI's own stdout stays parseable by whatever is piping it.
    if json {
        let _ = tracing_subscriber::fmt()
            .json()
            .with_env_filter(filter)
            .with_current_span(false)
            .with_writer(std::io::stderr)
            .try_init();
    } else {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(false)
            .with_writer(std::io::stderr)
            .try_init();
    }
}
