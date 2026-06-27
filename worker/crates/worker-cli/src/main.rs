//! hydra-worker — headless worker CLI.
//!
//! Token input is read from a no-echo prompt (or `HYDRA_PROVIDER_TOKEN` for automation),
//! never from argv, and is echoed back only as a masked fingerprint. The CLI is a thin shell
//! over `worker-core`: it never prints or transmits a raw token.

use std::path::PathBuf;

use clap::{Parser, Subcommand};
use worker_core::adapters::build_external_adapter;
use worker_core::config::WorkerConfig;
use worker_core::types::ExecutionMode;
use worker_core::usage::{JsonUsageStore, UsageStore};
use worker_core::vault::{EncryptedFileStore, Secret, Vault};

#[derive(Parser)]
#[command(name = "hydra-worker", about = "hydra-ai local AI execution gateway")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// First-run mode chooser: local model / provider / both.
    Init {
        #[arg(long, value_parser = ["local", "provider", "both"])]
        mode: Option<String>,
    },
    /// Manage provider tokens (stored locally; never sent to the coordinator).
    Provider {
        #[command(subcommand)]
        action: ProviderAction,
    },
    /// Show usage metrics for external providers.
    Usage {
        #[arg(long)]
        period: Option<String>,
    },
    /// Connect to the coordinator and process leased jobs.
    Run,
}

#[derive(Subcommand)]
enum ProviderAction {
    /// Add a provider token (entered interactively).
    Add {
        name: String,
        /// Override base URL (required for `custom`).
        #[arg(long)]
        base_url: Option<String>,
    },
    /// Test a provider's stored token against its API.
    Test {
        name: String,
        #[arg(long)]
        base_url: Option<String>,
    },
    /// Remove a provider token.
    Rm { name: String },
    /// Rotate (replace) a provider token.
    Rotate { name: String },
}

fn config_dir() -> PathBuf {
    directories::ProjectDirs::from("ai", "hydra", "worker")
        .map(|d| d.config_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".hydra"))
}

fn config_path() -> PathBuf {
    config_dir().join("config.json")
}

/// Build the vault. Passphrase from `HYDRA_VAULT_PASSPHRASE` or a no-echo prompt.
fn open_vault() -> Vault {
    let pass = std::env::var("HYDRA_VAULT_PASSPHRASE")
        .unwrap_or_else(|_| rpassword::prompt_password("Vault passphrase: ").unwrap_or_default());
    Vault::new(Box::new(EncryptedFileStore::new(
        EncryptedFileStore::default_path(),
        pass,
    )))
}

fn read_token() -> Secret {
    let raw = std::env::var("HYDRA_PROVIDER_TOKEN")
        .ok()
        .or_else(|| rpassword::prompt_password("Provider token: ").ok())
        .unwrap_or_default();
    Secret::new(raw.trim().to_string())
}

fn load_config() -> Option<WorkerConfig> {
    std::fs::read(config_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

fn save_config(cfg: &WorkerConfig) -> std::io::Result<()> {
    std::fs::create_dir_all(config_dir())?;
    std::fs::write(config_path(), serde_json::to_vec_pretty(cfg).unwrap())
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    match cli.command {
        Command::Init { mode } => cmd_init(mode),
        Command::Provider { action } => cmd_provider(action).await,
        Command::Usage { period } => cmd_usage(period),
        Command::Run => cmd_run().await,
    }
}

fn cmd_init(mode: Option<String>) {
    let mode = mode.unwrap_or_else(|| {
        println!("Choose how this worker should process AI jobs:");
        println!("  [1] Use a local model on this machine");
        println!("  [2] Connect my own API provider token");
        println!("  [3] Use both local models and API providers");
        print!("> ");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        let mut s = String::new();
        let _ = std::io::stdin().read_line(&mut s);
        match s.trim() {
            "1" => "local",
            "2" => "provider",
            _ => "both",
        }
        .to_string()
    });
    let exec = match mode.as_str() {
        "local" => ExecutionMode::LocalModel,
        "provider" => ExecutionMode::ExternalProvider,
        _ => ExecutionMode::Both,
    };
    let worker_id = format!("worker-{}", std::process::id());
    let cfg = WorkerConfig::new(worker_id, exec);
    match save_config(&cfg) {
        Ok(()) => println!("Initialized worker '{}' in {:?} mode.", cfg.worker_id, exec),
        Err(e) => eprintln!("failed to write config: {e}"),
    }
}

async fn cmd_provider(action: ProviderAction) {
    let vault = open_vault();
    match action {
        ProviderAction::Add { name, base_url: _ } => {
            let token = read_token();
            if token.expose().is_empty() {
                eprintln!("no token provided");
                return;
            }
            let fp = token.fingerprint();
            match vault.add(&name, token) {
                Ok(()) => println!("Stored token for '{name}' ({fp})."),
                Err(e) => eprintln!("vault error: {e}"),
            }
        }
        ProviderAction::Test { name, base_url } => {
            let Some(token) = vault.get(&name).ok().flatten() else {
                eprintln!("no token stored for '{name}'");
                return;
            };
            let fp = token.fingerprint();
            match build_external_adapter(&name, base_url, token, reqwest::Client::new()) {
                Ok(adapter) => match adapter.validate_credentials().await {
                    Ok(true) => println!("'{name}' ({fp}): credentials OK"),
                    Ok(false) => println!("'{name}' ({fp}): credentials REJECTED"),
                    Err(e) => eprintln!("'{name}' ({fp}): error: {e}"),
                },
                Err(e) => eprintln!("{e}"),
            }
        }
        ProviderAction::Rm { name } => match vault.remove(&name) {
            Ok(()) => println!("Removed token for '{name}'."),
            Err(e) => eprintln!("vault error: {e}"),
        },
        ProviderAction::Rotate { name } => {
            let token = read_token();
            let fp = token.fingerprint();
            match vault.rotate(&name, token) {
                Ok(()) => println!("Rotated token for '{name}' ({fp})."),
                Err(e) => eprintln!("vault error: {e}"),
            }
        }
    }
}

fn cmd_usage(period: Option<String>) {
    let store = match JsonUsageStore::new(JsonUsageStore::default_path()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("usage store error: {e}");
            return;
        }
    };
    let rows = store.query(period.as_deref()).unwrap_or_default();
    if rows.is_empty() {
        println!(
            "No usage recorded{}.",
            period.map(|p| format!(" for {p}")).unwrap_or_default()
        );
        return;
    }
    println!(
        "{:<12} {:<18} {:<9} {:>8} {:>8} {:>9} {:>6} {:>6} {:>9}",
        "provider", "model", "period", "req", "in_tok", "out_tok", "ok", "fail", "cost_usd"
    );
    for r in rows {
        println!(
            "{:<12} {:<18} {:<9} {:>8} {:>8} {:>9} {:>6} {:>6} {:>9.4}",
            r.provider,
            r.model,
            r.period,
            r.requests,
            r.input_tokens,
            r.output_tokens,
            r.successful_jobs,
            r.failed_jobs,
            r.estimated_cost_usd
        );
    }
}

async fn cmd_run() {
    let Some(cfg) = load_config() else {
        eprintln!("no config found — run `hydra-worker init` first");
        return;
    };
    // Build the (non-secret) registration to confirm what the coordinator would see.
    // The persistent Phoenix Channel transport is layered on top of this payload.
    let reg = worker_core::registration::WorkerRegistration::build(&cfg, None, None, &[]);
    println!(
        "Worker '{}' ready in {:?} mode.",
        cfg.worker_id, cfg.execution_mode
    );
    println!("Registration payload the coordinator will receive (no secrets):");
    println!("{}", serde_json::to_string_pretty(&reg).unwrap());
    println!("\n(transport) connect to coordinator channel and process leases — see worker-core::coordinator_client");
}
