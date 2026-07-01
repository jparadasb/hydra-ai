//! Background worker runner for the desktop app: Start / Stop / live status.
//!
//! Wraps the shared `worker_core::worker_run` path (same code the CLI uses) in a cancellable
//! background task. The UI calls [`Runner::start`] / [`Runner::stop`] and polls
//! [`Runner::status`]. The vault passphrase is supplied per start and never stored here beyond
//! the in-flight task.

use std::sync::{Arc, Mutex};

use tokio::task::JoinHandle;

use worker_core::worker_run::{self, RunParams, RunStatus, RunStatusView};

use crate::support;

/// Owns the running worker task + its shared status.
pub struct Runner {
    status: Arc<RunStatus>,
    task: Mutex<Option<JoinHandle<()>>>,
}

impl Default for Runner {
    fn default() -> Self {
        Self {
            status: RunStatus::new(),
            task: Mutex::new(None),
        }
    }
}

impl Runner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start processing jobs. `coordinator_url` overrides config/env when `Some`. Errors if a
    /// run is already active. Must be called from within a Tokio runtime (Tauri provides one).
    pub fn start(&self, passphrase: String, coordinator_url: Option<String>) -> Result<(), String> {
        let mut guard = self.task.lock().unwrap();
        if guard.as_ref().is_some_and(|h| !h.is_finished()) {
            return Err("worker already running".into());
        }

        let cfg = support::ensure_config();
        let status = Arc::clone(&self.status);
        // Mark running synchronously so an immediate status poll reflects the start.
        status.mark_running();

        let params = RunParams {
            config: cfg,
            passphrase,
            coordinator_url,
            join_token: None,
        };
        let task_status = Arc::clone(&status);
        let handle = tokio::spawn(async move {
            if let Err(e) = worker_run::build_and_run(params, Arc::clone(&task_status)).await {
                task_status.mark_stopped(Some(e.to_string()));
            }
        });
        *guard = Some(handle);
        Ok(())
    }

    /// Stop the running worker (aborts the task + drops the socket). Idempotent.
    pub fn stop(&self) {
        if let Some(handle) = self.task.lock().unwrap().take() {
            handle.abort();
        }
        self.status.mark_stopped(None);
    }

    pub fn status(&self) -> RunStatusView {
        self.status.view()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_status_is_not_running() {
        let r = Runner::new();
        let v = r.status();
        assert!(!v.running && !v.connected && v.jobs_processed == 0);
        // stop() on an idle runner is a no-op.
        r.stop();
        assert!(!r.status().running);
    }
}
