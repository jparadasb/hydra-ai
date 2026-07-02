//! hydra-worker desktop app (Tauri 2).
//!
//! Thin shell over `worker-tauri`: every `#[tauri::command]` delegates to the tested command
//! layer and returns only display-safe DTOs. The raw provider token enters `add_provider` /
//! `rotate_provider` from the UI's secure input and is moved straight into the vault — it is
//! never returned to the UI, logged, or sent to the coordinator.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use serde_json::json;
use tauri::State;

use worker_core::config::Preference;
use worker_core::types::{ExecutionMode, PrivacyLevel};
use worker_tauri::dto::{ProviderView, TestResult, UsageRow};
use worker_tauri::support;

/// Holds the vault passphrase for this session (set via [`unlock`]) and the background worker
/// runner (Start/Stop).
#[derive(Default)]
struct AppState {
    pass: Mutex<Option<String>>,
    runner: worker_tauri::Runner,
}

impl AppState {
    fn passphrase(&self) -> Result<String, String> {
        self.pass
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| "vault locked — unlock first".to_string())
    }
}

/// Unlock the vault for this session with the user's passphrase.
#[tauri::command]
fn unlock(state: State<'_, AppState>, passphrase: String) -> bool {
    *state.pass.lock().unwrap() = Some(passphrase);
    true
}

/// Current non-secret config for the UI (mode, providers, privacy, coordinator).
#[tauri::command]
fn get_config() -> serde_json::Value {
    let cfg = support::ensure_config();
    json!({
        "worker_id": cfg.worker_id,
        "execution_mode": mode_str(cfg.execution_mode),
        "coordinator_url": cfg.coordinator_url,
        "providers": cfg.providers.iter().map(|p| &p.name).collect::<Vec<_>>(),
        "routing_preference": pref_str(cfg.routing.preference),
        "privacy": {
            "accepted_job_levels": cfg.privacy.accepted_job_levels.iter().map(|l| level_str(*l)).collect::<Vec<_>>(),
            "allow_private_jobs": cfg.privacy.allow_private_jobs,
            "allow_sensitive_jobs": cfg.privacy.allow_sensitive_jobs,
        }
    })
}

/// Choose execution mode: `local` | `provider` | `both`.
#[tauri::command]
fn set_mode(mode: String) -> Result<(), String> {
    let mut cfg = support::ensure_config();
    cfg.execution_mode = match mode.as_str() {
        "local" => ExecutionMode::LocalModel,
        "provider" => ExecutionMode::ExternalProvider,
        "both" => ExecutionMode::Both,
        other => return Err(format!("unknown mode: {other}")),
    };
    support::save_config(&cfg).map_err(|e| e.to_string())
}

/// Store a provider token (entered in the UI). Returns a masked fingerprint only.
#[tauri::command]
fn add_provider(
    state: State<'_, AppState>,
    name: String,
    base_url: Option<String>,
    token: String,
) -> Result<ProviderView, String> {
    let pass = state.passphrase()?;
    let view = support::build_commands(pass).add_provider(&name, token)?;
    let mut cfg = support::ensure_config();
    cfg.upsert_provider(&name, base_url);
    support::save_config(&cfg).map_err(|e| e.to_string())?;
    Ok(view)
}

/// Sign in to a provider with a browser (OAuth). `name` is `gemini` (Google / Code Assist) or
/// `openai` (ChatGPT sign-in that mints an API key). Stores the credential in the vault and
/// records the provider in config. Returns a masked fingerprint only.
#[tauri::command]
async fn login_provider(
    state: State<'_, AppState>,
    name: String,
) -> Result<ProviderView, String> {
    let pass = state.passphrase()?;
    let view = support::build_commands(pass).login_provider(&name).await?;
    let mut cfg = support::ensure_config();
    cfg.upsert_provider(&view.name, None);
    support::save_config(&cfg).map_err(|e| e.to_string())?;
    Ok(view)
}

/// Configured providers with masked fingerprints (never tokens).
#[tauri::command]
fn list_providers(state: State<'_, AppState>) -> Result<Vec<ProviderView>, String> {
    let pass = state.passphrase()?;
    Ok(support::build_commands(pass).list_providers(&support::provider_names()))
}

/// Validate a stored provider token against its API.
#[tauri::command]
async fn test_provider(
    state: State<'_, AppState>,
    name: String,
    base_url: Option<String>,
) -> Result<TestResult, String> {
    let pass = state.passphrase()?;
    Ok(support::build_commands(pass).test_provider(&name, base_url).await)
}

/// Replace an existing provider token.
#[tauri::command]
fn rotate_provider(
    state: State<'_, AppState>,
    name: String,
    token: String,
) -> Result<ProviderView, String> {
    let pass = state.passphrase()?;
    support::build_commands(pass).rotate_provider(&name, token)
}

/// Remove a provider token and its config entry.
#[tauri::command]
fn remove_provider(state: State<'_, AppState>, name: String) -> Result<(), String> {
    let pass = state.passphrase()?;
    support::build_commands(pass).remove_provider(&name)?;
    let mut cfg = support::ensure_config();
    cfg.providers.retain(|p| p.name != name);
    support::save_config(&cfg).map_err(|e| e.to_string())
}

/// Update privacy preferences + routing preference.
#[tauri::command]
fn set_privacy(
    accepted_levels: Vec<String>,
    allow_private: bool,
    allow_sensitive: bool,
    routing_preference: String,
) -> Result<(), String> {
    let mut cfg = support::ensure_config();
    cfg.privacy.accepted_job_levels = accepted_levels
        .iter()
        .filter_map(|s| parse_level(s))
        .collect();
    cfg.privacy.allow_private_jobs = allow_private;
    cfg.privacy.allow_sensitive_jobs = allow_sensitive;
    cfg.routing.preference = parse_pref(&routing_preference)?;
    support::save_config(&cfg).map_err(|e| e.to_string())
}

/// Usage rows for the UI table.
#[tauri::command]
fn usage(state: State<'_, AppState>, period: Option<String>) -> Result<Vec<UsageRow>, String> {
    let pass = state.passphrase()?;
    Ok(support::build_commands(pass).usage(period))
}

/// Start processing jobs: connect to the coordinator and run the gateway loop in the
/// background. `coordinator_url` overrides config/env when provided. Requires the vault to be
/// unlocked. Async so the inner task spawns within Tauri's Tokio runtime.
#[tauri::command]
async fn start_worker(
    state: State<'_, AppState>,
    coordinator_url: Option<String>,
) -> Result<(), String> {
    let pass = state.passphrase()?;
    state.runner.start(pass, coordinator_url)
}

/// Stop the running worker (disconnects + halts the lease loop).
#[tauri::command]
fn stop_worker(state: State<'_, AppState>) {
    state.runner.stop();
}

/// Live worker run status for the UI to poll (running / connected / jobs / last error).
#[tauri::command]
fn worker_status(state: State<'_, AppState>) -> worker_core::worker_run::RunStatusView {
    state.runner.status()
}

fn main() {
    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            unlock,
            get_config,
            set_mode,
            add_provider,
            login_provider,
            list_providers,
            test_provider,
            rotate_provider,
            remove_provider,
            set_privacy,
            usage,
            start_worker,
            stop_worker,
            worker_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running hydra-worker app");
}

// ---- string <-> enum helpers ----

fn mode_str(m: ExecutionMode) -> &'static str {
    match m {
        ExecutionMode::LocalModel => "local",
        ExecutionMode::ExternalProvider => "provider",
        ExecutionMode::Both => "both",
    }
}

fn level_str(l: PrivacyLevel) -> &'static str {
    match l {
        PrivacyLevel::Public => "public",
        PrivacyLevel::Private => "private",
        PrivacyLevel::Sensitive => "sensitive",
        PrivacyLevel::LocalOnly => "local_only",
    }
}

fn parse_level(s: &str) -> Option<PrivacyLevel> {
    Some(match s {
        "public" => PrivacyLevel::Public,
        "private" => PrivacyLevel::Private,
        "sensitive" => PrivacyLevel::Sensitive,
        "local_only" => PrivacyLevel::LocalOnly,
        _ => return None,
    })
}

fn pref_str(p: Preference) -> &'static str {
    match p {
        Preference::PreferLocal => "prefer_local",
        Preference::PreferExternal => "prefer_external",
        Preference::ExternalOnly => "external_only",
        Preference::LocalOnly => "local_only",
    }
}

fn parse_pref(s: &str) -> Result<Preference, String> {
    Ok(match s {
        "prefer_local" => Preference::PreferLocal,
        "prefer_external" => Preference::PreferExternal,
        "external_only" => Preference::ExternalOnly,
        "local_only" => Preference::LocalOnly,
        other => return Err(format!("unknown routing preference: {other}")),
    })
}
