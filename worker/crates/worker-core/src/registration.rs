//! Builds the non-secret registration payload the worker sends to the coordinator.
//! Mirrors `proto/registration.schema.json`.
//!
//! By construction this type has no token/secret field, and it is the ONLY thing (besides
//! usage reports) serialized toward the coordinator.

use serde::{Deserialize, Serialize};

use crate::config::WorkerConfig;
use crate::types::{ExecutionMode, ModelInfo, PrivacyLevel};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeDescriptor {
    pub name: String,
    pub endpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderDescriptor {
    pub name: String,
    pub api_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Label only — NEVER the token. `"os_keychain"` or `"local_encrypted"`.
    pub token_storage: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistrationModel {
    pub name: String,
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_length: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modalities: Vec<String>,
    pub uses_external_provider: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyBlock {
    pub accepted_job_levels: Vec<PrivacyLevel>,
    pub allow_private_jobs: bool,
    pub allow_sensitive_jobs: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LimitsBlock {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_requests_per_hour: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_cost_per_day_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_parallel_provider_requests: Option<u32>,
}

/// The full registration payload. No secrets — enforced by construction + tests.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerRegistration {
    pub worker_id: String,
    pub execution_mode: ExecutionMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeDescriptor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<ProviderDescriptor>,
    pub models: Vec<RegistrationModel>,
    pub privacy: PrivacyBlock,
    pub limits: LimitsBlock,
    pub trust_level: String,
}

impl WorkerRegistration {
    /// Assemble the payload from config + the discovered model catalog. `runtime`/`provider`
    /// are descriptors only (no token).
    pub fn build(
        config: &WorkerConfig,
        runtime: Option<RuntimeDescriptor>,
        provider: Option<ProviderDescriptor>,
        catalog: &[ModelInfo],
    ) -> Self {
        WorkerRegistration {
            worker_id: config.worker_id.clone(),
            execution_mode: config.execution_mode,
            runtime,
            provider,
            models: catalog
                .iter()
                .map(|m| RegistrationModel {
                    name: m.name.clone(),
                    capabilities: m.capabilities.clone(),
                    context_length: m.context_length,
                    modalities: m.modalities.clone(),
                    uses_external_provider: m.uses_external_provider,
                })
                .collect(),
            privacy: PrivacyBlock {
                accepted_job_levels: config.privacy.accepted_job_levels.clone(),
                allow_private_jobs: config.privacy.allow_private_jobs,
                allow_sensitive_jobs: config.privacy.allow_sensitive_jobs,
            },
            limits: LimitsBlock {
                max_requests_per_hour: config.limits.max_requests_per_hour,
                max_cost_per_day_usd: config.limits.max_cost_per_day_usd,
                max_parallel_provider_requests: config.limits.max_parallel_provider_requests,
            },
            trust_level: "untrusted".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::WorkerConfig;

    #[test]
    fn registration_has_no_secret_fields() {
        let cfg = WorkerConfig::new("w1", ExecutionMode::ExternalProvider);
        let provider = ProviderDescriptor {
            name: "openai".into(),
            api_type: "openai_compatible".into(),
            base_url: Some("https://api.openai.com/v1".into()),
            token_storage: "os_keychain".into(),
        };
        let catalog = vec![ModelInfo {
            name: "gpt-4.1-mini".into(),
            capabilities: vec!["text.extract_json".into()],
            context_length: Some(128_000),
            modalities: vec!["text".into()],
            uses_external_provider: true,
        }];
        let reg = WorkerRegistration::build(&cfg, None, Some(provider), &catalog);
        let json = serde_json::to_string(&reg).unwrap().to_lowercase();
        for needle in [
            "\"token\"",
            "api_key",
            "authorization",
            "x-api-key",
            "bearer ",
            "sk-",
            "secret",
        ] {
            assert!(
                !json.contains(needle),
                "registration leaked `{needle}`: {json}"
            );
        }
        // token_storage is a label, not a secret
        assert!(json.contains("os_keychain"));
    }
}
