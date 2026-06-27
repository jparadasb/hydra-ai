//! Worker configuration: execution mode, routing policy, limits, privacy.
//!
//! This is the non-secret configuration. Tokens are NOT stored here — see [`crate::vault`].

use serde::{Deserialize, Serialize};

use crate::types::{ExecutionMode, PrivacyLevel};

/// How the worker prefers to route a job across its available backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Preference {
    PreferLocal,
    PreferExternal,
    ExternalOnly,
    LocalOnly,
}

/// Routing policy the worker applies before dispatching a leased job.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutingPolicy {
    pub preference: Preference,
    pub fallback_to_external_provider: bool,
    /// Privacy levels for which this worker is allowed to use an external provider.
    pub external_provider_allowed_privacy_levels: Vec<PrivacyLevel>,
}

impl Default for RoutingPolicy {
    fn default() -> Self {
        Self {
            preference: Preference::PreferLocal,
            fallback_to_external_provider: false,
            external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public],
        }
    }
}

/// Worker-side spend / rate guardrails enforced before any paid call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Limits {
    pub max_requests_per_hour: Option<u32>,
    pub max_cost_per_day_usd: Option<f64>,
    pub max_parallel_provider_requests: Option<u32>,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_requests_per_hour: Some(100),
            max_cost_per_day_usd: Some(5.0),
            max_parallel_provider_requests: Some(2),
        }
    }
}

/// Privacy preferences advertised to the coordinator and enforced locally.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyPrefs {
    pub accepted_job_levels: Vec<PrivacyLevel>,
    pub allow_private_jobs: bool,
    pub allow_sensitive_jobs: bool,
}

impl Default for PrivacyPrefs {
    fn default() -> Self {
        Self {
            accepted_job_levels: vec![PrivacyLevel::Public],
            allow_private_jobs: false,
            allow_sensitive_jobs: false,
        }
    }
}

/// A configured external provider. NON-SECRET: the token lives in the vault, keyed by `name`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderEntry {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
}

/// Top-level, non-secret worker configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerConfig {
    pub worker_id: String,
    pub execution_mode: ExecutionMode,
    #[serde(default)]
    pub routing: RoutingPolicy,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default)]
    pub privacy: PrivacyPrefs,
    /// External providers the user has configured (tokens are NOT here — see the vault).
    #[serde(default)]
    pub providers: Vec<ProviderEntry>,
    /// Coordinator base URL, e.g. `ws://127.0.0.1:4000`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinator_url: Option<String>,
}

impl WorkerConfig {
    pub fn new(worker_id: impl Into<String>, execution_mode: ExecutionMode) -> Self {
        Self {
            worker_id: worker_id.into(),
            execution_mode,
            routing: RoutingPolicy::default(),
            limits: Limits::default(),
            privacy: PrivacyPrefs::default(),
            providers: Vec::new(),
            coordinator_url: None,
        }
    }

    /// Add or update a provider entry (idempotent by name).
    pub fn upsert_provider(&mut self, name: impl Into<String>, base_url: Option<String>) {
        let name = name.into();
        match self.providers.iter_mut().find(|p| p.name == name) {
            Some(p) => p.base_url = base_url,
            None => self.providers.push(ProviderEntry { name, base_url }),
        }
    }
}
