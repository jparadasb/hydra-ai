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
