//! The thin command surface the desktop UI calls. Wraps `worker-core`. Returns only
//! display-safe DTOs (see [`crate::dto`]).

use worker_core::adapters::build_external_adapter;
use worker_core::usage::{JsonUsageStore, UsageStore};
use worker_core::vault::{Secret, Vault};

use crate::dto::{ProviderView, TestResult, UsageRow};

/// App state injected into Tauri commands: the vault + usage store handles.
pub struct Commands {
    vault: Vault,
    usage: JsonUsageStore,
    http: reqwest::Client,
}

impl Commands {
    pub fn new(vault: Vault, usage: JsonUsageStore) -> Self {
        Self {
            vault,
            usage,
            http: reqwest::Client::new(),
        }
    }

    /// Store a provider token. The raw token enters here from the UI's secure input and is
    /// immediately moved into the vault; the UI gets back only a fingerprint.
    pub fn add_provider(&self, name: &str, raw_token: String) -> Result<ProviderView, String> {
        let secret = Secret::new(raw_token);
        let fingerprint = secret.fingerprint();
        self.vault.add(name, secret).map_err(|e| e.to_string())?;
        Ok(ProviderView {
            name: name.to_string(),
            fingerprint,
            validated: false,
        })
    }

    /// List configured providers with masked fingerprints. Never returns tokens.
    pub fn list_providers(&self, names: &[String]) -> Vec<ProviderView> {
        names
            .iter()
            .filter_map(|name| {
                self.vault
                    .fingerprint(name)
                    .ok()
                    .flatten()
                    .map(|fp| ProviderView {
                        name: name.clone(),
                        fingerprint: fp,
                        validated: false,
                    })
            })
            .collect()
    }

    /// Validate a stored provider token against its API.
    pub async fn test_provider(&self, name: &str, base_url: Option<String>) -> TestResult {
        let Some(token) = self.vault.get(name).ok().flatten() else {
            return TestResult {
                name: name.to_string(),
                fingerprint: "—".into(),
                ok: false,
                error: Some("no token stored".into()),
            };
        };
        let fingerprint = token.fingerprint();
        match build_external_adapter(name, base_url, token, self.http.clone()) {
            Ok(adapter) => match adapter.validate_credentials().await {
                Ok(ok) => TestResult {
                    name: name.into(),
                    fingerprint,
                    ok,
                    error: None,
                },
                Err(e) => TestResult {
                    name: name.into(),
                    fingerprint,
                    ok: false,
                    error: Some(e.to_string()),
                },
            },
            Err(e) => TestResult {
                name: name.into(),
                fingerprint,
                ok: false,
                error: Some(e.to_string()),
            },
        }
    }

    pub fn rotate_provider(&self, name: &str, raw_token: String) -> Result<ProviderView, String> {
        let secret = Secret::new(raw_token);
        let fingerprint = secret.fingerprint();
        self.vault.rotate(name, secret).map_err(|e| e.to_string())?;
        Ok(ProviderView {
            name: name.into(),
            fingerprint,
            validated: false,
        })
    }

    pub fn remove_provider(&self, name: &str) -> Result<(), String> {
        self.vault.remove(name).map_err(|e| e.to_string())
    }

    /// Usage rows for the UI table.
    pub fn usage(&self, period: Option<String>) -> Vec<UsageRow> {
        self.usage
            .query(period.as_deref())
            .unwrap_or_default()
            .into_iter()
            .map(|r| {
                let average_latency_ms = r.average_latency_ms();
                UsageRow {
                    provider: r.provider,
                    model: r.model,
                    period: r.period,
                    requests: r.requests,
                    input_tokens: r.input_tokens,
                    output_tokens: r.output_tokens,
                    successful_jobs: r.successful_jobs,
                    failed_jobs: r.failed_jobs,
                    estimated_cost_usd: r.estimated_cost_usd,
                    average_latency_ms,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use worker_core::vault::EncryptedFileStore;

    fn commands(dir: &std::path::Path) -> Commands {
        let vault = Vault::new(Box::new(EncryptedFileStore::new(
            dir.join("vault.bin"),
            "pass".into(),
        )));
        let usage = JsonUsageStore::new(dir.join("usage.json")).unwrap();
        Commands::new(vault, usage)
    }

    #[test]
    fn add_and_list_return_only_fingerprints() {
        let dir = tempfile::tempdir().unwrap();
        let c = commands(dir.path());
        let view = c
            .add_provider("openai", "sk-supersecret-9999".into())
            .unwrap();
        assert_eq!(view.fingerprint, "sk-...9999");

        let listed = c.list_providers(&["openai".into()]);
        let json = serde_json::to_string(&listed).unwrap();
        // The raw secret must never appear in anything the UI receives.
        assert!(!json.contains("supersecret"));
        assert!(json.contains("sk-...9999"));
    }

    #[test]
    fn remove_provider_clears_it() {
        let dir = tempfile::tempdir().unwrap();
        let c = commands(dir.path());
        c.add_provider("openai", "sk-aaaa1111".into()).unwrap();
        c.remove_provider("openai").unwrap();
        assert!(c.list_providers(&["openai".into()]).is_empty());
    }
}
