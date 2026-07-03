//! Assemble runtime objects (adapter registry, gateway) from a [`WorkerConfig`] + [`Vault`].
//! Shared by the CLI and the desktop app so wiring lives in one place.

use std::sync::Arc;

use crate::adapter::AdapterRegistry;
use crate::adapters::{build_external_adapter, LocalOpenAiAdapter, OllamaAdapter};
use crate::config::WorkerConfig;
use crate::types::ExecutionMode;
use crate::vault::Vault;

/// Build the adapter registry from config: one adapter per configured provider whose token is
/// present in the vault, plus a local Ollama adapter when the mode includes local models.
///
/// Tokens are read from the vault and moved straight into their adapter — they never surface
/// to the caller.
pub fn build_registry(
    config: &WorkerConfig,
    vault: &Vault,
    http: reqwest::Client,
) -> AdapterRegistry {
    let mut registry = AdapterRegistry::new();

    if matches!(
        config.execution_mode,
        ExecutionMode::LocalModel | ExecutionMode::Both
    ) {
        // Register all supported local runtimes at their default endpoints. Only the ones
        // actually running contribute models — the gateway tolerates a runtime whose
        // `list_models` fails (it just yields no models).
        registry.register(Arc::new(OllamaAdapter::new(http.clone())));
        registry.register(Arc::new(LocalOpenAiAdapter::llama_cpp(http.clone())));
        registry.register(Arc::new(LocalOpenAiAdapter::vllm(http.clone())));
        registry.register(Arc::new(LocalOpenAiAdapter::lm_studio(http.clone())));
    }

    if matches!(
        config.execution_mode,
        ExecutionMode::ExternalProvider | ExecutionMode::Both
    ) {
        for entry in &config.providers {
            let Some(token) = vault.get(&entry.name).ok().flatten() else {
                continue; // no token stored yet; skip
            };
            if let Ok(adapter) =
                build_external_adapter(&entry.name, entry.base_url.clone(), token, http.clone())
            {
                registry.register(adapter);
            }
        }
    }

    registry
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::{OAuthTokens, FLAVOR_GOOGLE_CODE_ASSIST};
    use crate::vault::{EncryptedFileStore, Secret};

    // A worker configured with a Gemini OAuth provider must advertise that provider's models
    // (with non-empty capabilities) in its catalog — i.e. build_registry -> adapter ->
    // list_models produces the capabilities the coordinator routes on.
    #[tokio::test]
    async fn external_gemini_oauth_provider_advertises_capabilities() {
        let dir = tempfile::tempdir().unwrap();
        let vault = Vault::new(Box::new(EncryptedFileStore::new(
            dir.path().join("vault.bin"),
            "pass".into(),
        )));

        let blob = OAuthTokens {
            flavor: FLAVOR_GOOGLE_CODE_ASSIST.into(),
            access_token: "ya29.test".into(),
            refresh_token: Some("1//r".into()),
            expires_at_unix: crate::oauth::now_unix() + 3600,
            project_id: Some("proj-1".into()),
            account_id: None,
        }
        .to_vault_value();
        vault.add("gemini", Secret::new(blob)).unwrap();

        let mut cfg = WorkerConfig::new("w-gemini", ExecutionMode::ExternalProvider);
        cfg.upsert_provider("gemini", None);

        let registry = build_registry(&cfg, &vault, reqwest::Client::new());
        let adapter = registry.get("gemini").expect("gemini adapter must be registered");
        let models = adapter.list_models().await.expect("Code Assist list_models is static");

        assert!(!models.is_empty(), "gemini OAuth provider advertised no models");
        assert!(
            models.iter().all(|m| !m.capabilities.is_empty()),
            "gemini models advertised empty capabilities"
        );
        assert!(models.iter().any(|m| m.capabilities.iter().any(|c| c == "chat")));
    }

    // Control: an ExternalProvider worker with NO providers in config builds no external
    // adapter, so its catalog is empty — reproducing the "capabilities are empty" symptom.
    #[tokio::test]
    async fn external_worker_without_configured_provider_has_no_adapters() {
        let dir = tempfile::tempdir().unwrap();
        let vault = Vault::new(Box::new(EncryptedFileStore::new(
            dir.path().join("vault.bin"),
            "pass".into(),
        )));
        // execution_mode is external, but no providers configured.
        let cfg = WorkerConfig::new("w-empty", ExecutionMode::ExternalProvider);

        let registry = build_registry(&cfg, &vault, reqwest::Client::new());
        assert!(registry.get("gemini").is_err(), "no provider should be registered");
    }
}
