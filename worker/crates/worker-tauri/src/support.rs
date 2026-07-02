//! Config IO + `Commands` construction shared by the desktop app. Lives here (not in the app
//! crate) so it is unit-tested in the workspace without the Tauri/webkit runtime.

use std::path::PathBuf;

use worker_core::config::WorkerConfig;
use worker_core::types::ExecutionMode;
use worker_core::usage::JsonUsageStore;
use worker_core::vault::{EncryptedFileStore, Vault};

use crate::commands::Commands;

pub fn config_dir() -> PathBuf {
    directories::ProjectDirs::from("ai", "hydra", "worker")
        .map(|d| d.config_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".hydra"))
}

pub fn config_path() -> PathBuf {
    config_dir().join("config.json")
}

pub fn load_config() -> Option<WorkerConfig> {
    std::fs::read(config_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

pub fn save_config(cfg: &WorkerConfig) -> std::io::Result<()> {
    std::fs::create_dir_all(config_dir())?;
    std::fs::write(config_path(), serde_json::to_vec_pretty(cfg).unwrap())
}

/// Ensure a config exists; create a default in `Both` mode on first run.
pub fn ensure_config() -> WorkerConfig {
    load_config().unwrap_or_else(|| {
        let cfg = WorkerConfig::new(
            format!("worker-{}", std::process::id()),
            ExecutionMode::Both,
        );
        let _ = save_config(&cfg);
        cfg
    })
}

/// Provider names the UI should list (from config; tokens stay in the vault).
pub fn provider_names() -> Vec<String> {
    load_config()
        .map(|c| c.providers.into_iter().map(|p| p.name).collect())
        .unwrap_or_default()
}

/// Wipe the encrypted vault and forget configured providers — used by the UI "reset vault"
/// action (e.g. when the passphrase is lost). The next unlock defines a fresh passphrase.
pub fn reset_vault() -> std::io::Result<()> {
    let path = EncryptedFileStore::default_path();
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    if let Some(mut cfg) = load_config() {
        cfg.providers.clear();
        let _ = save_config(&cfg);
    }
    Ok(())
}

/// Build the command surface backed by the default vault + usage store.
pub fn build_commands(passphrase: impl Into<String>) -> Commands {
    let vault = Vault::new(Box::new(EncryptedFileStore::new(
        EncryptedFileStore::default_path(),
        passphrase.into(),
    )));
    // A missing/at-default usage file is fine; fall back to a temp path on error.
    let usage = JsonUsageStore::new(JsonUsageStore::default_path()).unwrap_or_else(|_| {
        JsonUsageStore::new(std::env::temp_dir().join("hydra-usage.json")).unwrap()
    });
    Commands::new(vault, usage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_commands_roundtrips_a_provider() {
        // Uses the default vault path with a temp passphrase; just checks the wiring holds.
        let cmds = build_commands("test-pass");
        let view = cmds.add_provider("smoke-test-provider", "sk-smoke-9999".into());
        assert!(view.is_ok());
        let v = view.unwrap();
        assert_eq!(v.fingerprint, "sk-...9999");
        let _ = cmds.remove_provider("smoke-test-provider");
    }
}
