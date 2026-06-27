//! Data the UI is allowed to see. No secrets — fingerprints and metadata only.

use serde::{Deserialize, Serialize};

/// A configured provider as shown in the UI. Carries a masked fingerprint, never a token.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderView {
    pub name: String,
    /// e.g. `sk-...abcd`. Display only.
    pub fingerprint: String,
    pub validated: bool,
}

/// One usage row for the UI table.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageRow {
    pub provider: String,
    pub model: String,
    pub period: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub successful_jobs: u64,
    pub failed_jobs: u64,
    pub estimated_cost_usd: f64,
    pub average_latency_ms: f64,
}

/// Result of a token validation test.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    pub name: String,
    pub fingerprint: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
