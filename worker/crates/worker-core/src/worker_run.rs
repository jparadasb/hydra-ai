//! Shared "connect to the coordinator and process jobs" path, used by both the headless CLI
//! (`hydra-worker run`) and the desktop app's Start/Stop. Keeping it here means the CLI and UI
//! run identical logic — identity, device-key auth, gateway, and the lease loop — with no
//! drift. Feature-gated on `transport` (it pulls the networked client).
//!
//! [`RunStatus`] is a cheap shared snapshot the UI polls: running / connected / jobs processed
//! / last error. The lease loop updates it live.

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;

use crate::bootstrap::build_registry;
use crate::config::WorkerConfig;
use crate::coordinator_client::{connect_and_run, ClientConfig};
use crate::error::{Error, Result};
use crate::gateway::Gateway;
use crate::identity::{machine_worker_id, DeviceKey};
use crate::limits::LimitGuard;
use crate::registration::{ProviderDescriptor, WorkerRegistration};
use crate::usage::JsonUsageStore;
use crate::vault::{EncryptedFileStore, Vault};

/// Live, shareable status of a worker run. Cloneable via `Arc`; updated by the lease loop.
#[derive(Debug, Default)]
pub struct RunStatus {
    running: AtomicBool,
    connected: AtomicBool,
    jobs_processed: AtomicU64,
    started_unix: AtomicI64,
    last_error: Mutex<Option<String>>,
}

/// Serializable snapshot handed to the UI.
#[derive(Debug, Clone, Serialize)]
pub struct RunStatusView {
    pub running: bool,
    pub connected: bool,
    pub jobs_processed: u64,
    pub started_unix: i64,
    pub last_error: Option<String>,
}

impl RunStatus {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Mark the run as started; clears any previous error.
    pub fn mark_running(&self) {
        self.running.store(true, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        self.jobs_processed.store(0, Ordering::SeqCst);
        self.started_unix.store(now_unix(), Ordering::SeqCst);
        *self.last_error.lock().unwrap() = None;
    }

    /// Set the live socket-connected flag.
    pub fn mark_connected(&self, connected: bool) {
        self.connected.store(connected, Ordering::SeqCst);
    }

    pub fn incr_jobs(&self) {
        self.jobs_processed.fetch_add(1, Ordering::SeqCst);
    }

    /// Record a transient error (e.g. a failed connect) without changing the running state —
    /// the reconnect loop keeps going. Surfaced to the UI as `last_error`.
    pub fn note_error(&self, error: String) {
        *self.last_error.lock().unwrap() = Some(error);
    }

    /// Mark the run stopped, recording an error if one ended it.
    pub fn mark_stopped(&self, error: Option<String>) {
        self.running.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        if error.is_some() {
            *self.last_error.lock().unwrap() = error;
        }
    }

    pub fn view(&self) -> RunStatusView {
        RunStatusView {
            running: self.running.load(Ordering::SeqCst),
            connected: self.connected.load(Ordering::SeqCst),
            jobs_processed: self.jobs_processed.load(Ordering::SeqCst),
            started_unix: self.started_unix.load(Ordering::SeqCst),
            last_error: self.last_error.lock().unwrap().clone(),
        }
    }
}

/// Inputs for a run. `coordinator_url` / `join_token` are explicit overrides (e.g. from a UI
/// field); when `None`, they are resolved from env / config / build-time bake / default.
pub struct RunParams {
    pub config: WorkerConfig,
    pub passphrase: String,
    pub coordinator_url: Option<String>,
    pub join_token: Option<String>,
}

/// Resolve the coordinator URL: explicit > `HYDRA_COORDINATOR_URL` > config > baked > default.
pub fn resolve_coordinator_url(explicit: Option<String>, cfg: &WorkerConfig) -> String {
    explicit
        .or_else(|| std::env::var("HYDRA_COORDINATOR_URL").ok())
        .or_else(|| cfg.coordinator_url.clone())
        .or_else(|| option_env!("HYDRA_COORDINATOR_URL").map(str::to_string))
        .unwrap_or_else(|| "ws://127.0.0.1:4000".to_string())
}

/// Resolve the optional shared join token: explicit > `HYDRA_JOIN_TOKEN` > baked.
pub fn resolve_join_token(explicit: Option<String>) -> Option<String> {
    explicit
        .or_else(|| std::env::var("HYDRA_JOIN_TOKEN").ok())
        .or_else(|| option_env!("HYDRA_JOIN_TOKEN").map(str::to_string))
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// Build the gateway + registration + device-key auth from `params`, then connect to the
/// coordinator and process leased jobs until the socket closes (or the task is cancelled).
/// Updates `status` throughout.
pub async fn build_and_run(params: RunParams, status: Arc<RunStatus>) -> Result<()> {
    let mut cfg = params.config;
    // Identity is machine-derived (not the stored id) and proven by the device key.
    cfg.worker_id = machine_worker_id();
    let url = resolve_coordinator_url(params.coordinator_url, &cfg);
    let join_token = resolve_join_token(params.join_token);

    let vault = Vault::new(Box::new(EncryptedFileStore::new(
        EncryptedFileStore::default_path(),
        params.passphrase,
    )));
    let http = reqwest::Client::new();
    let registry = build_registry(&cfg, &vault, http.clone());
    let usage = Arc::new(
        JsonUsageStore::new(JsonUsageStore::default_path())
            .map_err(|e| Error::Other(format!("usage store: {e}")))?,
    );
    let mut gateway = Gateway::new(
        registry,
        cfg.routing.clone(),
        LimitGuard::new(cfg.limits.clone()),
        usage,
    );
    gateway.refresh_catalog().await;

    let provider_desc = cfg.providers.first().map(|p| ProviderDescriptor {
        name: p.name.clone(),
        api_type: "openai_compatible".into(),
        base_url: p.base_url.clone(),
        token_storage: "local_encrypted".into(),
    });
    let reg = WorkerRegistration::build(&cfg, None, provider_desc, &gateway.model_catalog());
    let registration = serde_json::to_value(&reg)?;

    let device_key = DeviceKey::load_or_create(&DeviceKey::default_path())?;
    let gateway = Arc::new(gateway);

    status.mark_running();

    // Reconnect-with-backoff. A worker is a long-running daemon: a dropped socket (coordinator
    // restart, network blip) or a failed connect must not end the run — we retry forever. The
    // loop only stops when the task is cancelled (desktop Stop -> `Runner::stop` aborts it) or
    // the process exits (CLI Ctrl-C). Backoff grows on repeated *connect failures* and resets
    // after a connection that actually came up, so a brief outage recovers fast while a downed
    // coordinator isn't hammered.
    let base = Duration::from_secs(1);
    let max = Duration::from_secs(30);
    let mut backoff = base;

    loop {
        // Re-sign auth every attempt: the device-key challenge (ts|nonce|sig) is only fresh for
        // a short window on the coordinator, so a reused signature is rejected on reconnect.
        let auth = device_key.auth_params(&cfg.worker_id);
        let client = ClientConfig {
            base_url: url.clone(),
            worker_id: cfg.worker_id.clone(),
            registration: registration.clone(),
            heartbeat: Duration::from_secs(30),
            join_token: join_token.clone(),
            auth: Some(auth),
        };

        match connect_and_run(client, Arc::clone(&gateway), Arc::clone(&status)).await {
            // Connected then disconnected: recover quickly.
            Ok(()) => backoff = base,
            // Never connected: record why, then back off harder.
            Err(e) => status.note_error(e.to_string()),
        }

        tokio::time::sleep(backoff + jitter(backoff)).await;
        backoff = (backoff * 2).min(max);
    }
}

// Up to +25% jitter so many workers reconnecting after the same outage don't synchronize.
fn jitter(d: Duration) -> Duration {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|t| t.subsec_nanos())
        .unwrap_or(0);
    let pct = (nanos % 250) as u128; // 0..249 -> up to ~24.9%
    Duration::from_millis((d.as_millis() * pct / 1000) as u64)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_defaults_and_transitions() {
        let s = RunStatus::new();
        let v = s.view();
        assert!(!v.running && !v.connected && v.jobs_processed == 0 && v.last_error.is_none());

        s.mark_running();
        s.mark_connected(true);
        s.incr_jobs();
        s.incr_jobs();
        let v = s.view();
        assert!(v.running && v.connected && v.jobs_processed == 2);
        assert!(v.started_unix > 0);

        s.mark_stopped(Some("boom".into()));
        let v = s.view();
        assert!(!v.running && !v.connected);
        assert_eq!(v.last_error.as_deref(), Some("boom"));
    }

    #[test]
    fn resolve_url_prefers_explicit_then_default() {
        let cfg = WorkerConfig::new("w", crate::types::ExecutionMode::Both);
        assert_eq!(
            resolve_coordinator_url(Some("wss://x".into()), &cfg),
            "wss://x"
        );
        // No explicit/env/config/baked -> built-in default (env not set in this test).
        std::env::remove_var("HYDRA_COORDINATOR_URL");
        assert_eq!(resolve_coordinator_url(None, &cfg), "ws://127.0.0.1:4000");
    }
}
