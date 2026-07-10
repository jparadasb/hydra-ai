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
#[command(
    name = "hydra-worker",
    version = version_str(),
    about = "hydra-ai local AI execution gateway"
)]
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
    /// Update this binary in place from the published GitHub release.
    Update {
        /// Only report whether an update is available (exit 10 if so); don't install.
        #[arg(long)]
        check: bool,
        /// Release channel: "edge" (rolling build of main, default), "latest" (newest tagged
        /// release), or a tag like "v0.2.0".
        #[arg(long, default_value = "edge")]
        channel: String,
        /// Override the download base URL (expects <url>/<asset> and <url>/<asset>.sha256).
        #[arg(long)]
        url: Option<String>,
        /// After a successful update, run `systemctl restart hydra-worker` (Linux only).
        #[arg(long)]
        restart: bool,
    },
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
    /// Sign in with a browser instead of pasting a key (gemini: Google account,
    /// openai: ChatGPT sign-in that mints an API key).
    Login {
        #[arg(value_parser = ["gemini", "google", "openai"])]
        name: String,
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

/// `--version` string, leaked once so clap can hold a `&'static str`.
fn version_str() -> &'static str {
    use std::sync::OnceLock;
    static V: OnceLock<String> = OnceLock::new();
    V.get_or_init(worker_core::self_update::build_version).as_str()
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
        Command::Update {
            check,
            channel,
            url,
            restart,
        } => cmd_update(check, channel, url, restart).await,
    }
}

/// Exit codes: 0 up to date / installed, 10 update available (check mode), 1 error.
async fn cmd_update(check: bool, channel: String, url: Option<String>, restart: bool) {
    use worker_core::self_update::{self, Channel, UpdateOptions, UpdateOutcome};

    let exe = match std::env::current_exe().and_then(std::fs::canonicalize) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("update: cannot locate current executable: {e}");
            std::process::exit(1);
        }
    };

    let opts = UpdateOptions {
        channel: Channel::parse(&channel),
        base_url: url,
        check_only: check,
        verify_exec: true,
        repo: self_update::DEFAULT_REPO.to_string(),
    };

    let client = reqwest::Client::new();
    match self_update::run_update(&client, &exe, &opts).await {
        Ok(UpdateOutcome::UpToDate { sha256 }) => {
            println!("Already up to date ({}).", short(&sha256));
        }
        Ok(UpdateOutcome::UpdateAvailable { current, remote }) => {
            let remote = remote.map(|r| short(&r)).unwrap_or_else(|| "unknown".into());
            println!(
                "Update available: local {} != remote {}. Run `hydra-worker update` to install.",
                short(&current),
                remote
            );
            std::process::exit(10);
        }
        Ok(UpdateOutcome::Updated { old, new, path }) => {
            println!("Updated {} -> {} ({}).", short(&old), short(&new), path.display());
            print_new_version(&path);
            if restart {
                restart_service();
            } else {
                println!("Restart the service to apply: sudo systemctl restart hydra-worker");
            }
        }
        Err(e) => {
            eprintln!("update failed: {e}");
            std::process::exit(1);
        }
    }
}

fn short(sha: &str) -> String {
    sha.chars().take(8).collect()
}

/// Print the freshly installed binary's `--version` so the operator sees exactly what landed.
fn print_new_version(path: &std::path::Path) {
    if let Ok(out) = std::process::Command::new(path).arg("--version").output() {
        if let Ok(s) = String::from_utf8(out.stdout) {
            let s = s.trim();
            if !s.is_empty() {
                println!("Now running: {s}");
            }
        }
    }
}

/// Linux-only service restart after an update. Non-Linux prints a hint instead.
fn restart_service() {
    if !cfg!(target_os = "linux") {
        println!("--restart is Linux/systemd only; restart the worker manually.");
        return;
    }
    match std::process::Command::new("systemctl")
        .args(["restart", "hydra-worker"])
        .status()
    {
        Ok(s) if s.success() => println!("Restarted hydra-worker.service."),
        Ok(s) => {
            eprintln!("systemctl restart hydra-worker exited with {s}");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("could not run systemctl ({e}); restart hydra-worker manually.");
            std::process::exit(1);
        }
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
    // Stable machine-derived id (the same value `run` will use + prove with the device key).
    let worker_id = worker_core::identity::machine_worker_id();
    let cfg = WorkerConfig::new(worker_id, exec);
    match save_config(&cfg) {
        Ok(()) => println!("Initialized worker '{}' in {:?} mode.", cfg.worker_id, exec),
        Err(e) => eprintln!("failed to write config: {e}"),
    }
}

async fn cmd_provider(action: ProviderAction) {
    let vault = open_vault();
    match action {
        ProviderAction::Add { name, base_url } => {
            let token = read_token();
            if token.expose().is_empty() {
                eprintln!("no token provided");
                return;
            }
            let fp = token.fingerprint();
            match vault.add(&name, token) {
                Ok(()) => {
                    // Record the provider (no token) in config so `run` can build its adapter.
                    if let Some(mut cfg) = load_config() {
                        cfg.upsert_provider(&name, base_url);
                        let _ = save_config(&cfg);
                    }
                    println!("Stored token for '{name}' ({fp}).");
                    print_external_provider_notice();
                }
                Err(e) => eprintln!("vault error: {e}"),
            }
        }
        ProviderAction::Login { name } => {
            let http = reqwest::Client::new();
            match name.as_str() {
                "gemini" | "google" => match worker_core::oauth::login_google(
                    &http,
                    worker_core::oauth::CaptureMode::LoopbackOrPaste,
                )
                .await
                {
                    Ok(tokens) => {
                        let project = tokens.project_id.clone().unwrap_or_default();
                        let secret = Secret::new(tokens.to_vault_value());
                        match vault.add("gemini", secret) {
                            Ok(()) => {
                                if let Some(mut cfg) = load_config() {
                                    cfg.upsert_provider("gemini", None);
                                    let _ = save_config(&cfg);
                                }
                                println!("Signed in to Google (Code Assist project '{project}').");
                                println!("Stored OAuth credential for 'gemini'.");
                                print_external_provider_notice();
                            }
                            Err(e) => eprintln!("vault error: {e}"),
                        }
                    }
                    Err(e) => eprintln!("gemini login failed: {e}"),
                },
                _ => match worker_core::oauth::login_openai(
                    &http,
                    worker_core::oauth::CaptureMode::LoopbackOrPaste,
                )
                .await
                {
                    Ok(tokens) => {
                        let acct = tokens.account_id.clone().unwrap_or_default();
                        match vault.add("openai", Secret::new(tokens.to_vault_value())) {
                            Ok(()) => {
                                if let Some(mut cfg) = load_config() {
                                    cfg.upsert_provider("openai", None);
                                    let _ = save_config(&cfg);
                                }
                                println!(
                                    "Signed in with ChatGPT (account {acct}); using the ChatGPT backend for 'openai'."
                                );
                                print_external_provider_notice();
                            }
                            Err(e) => eprintln!("vault error: {e}"),
                        }
                    }
                    Err(e) => eprintln!("openai login failed: {e}"),
                },
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

/// Printed after an external provider is added or signed in. Makes the sharing boundary
/// explicit: by default the key answers only the owner's own (private) requests, and
/// Hydra does not authorize pooling/reselling third-party API access.
fn print_external_provider_notice() {
    eprintln!(
        "\n\
         Note: this provider key is used only for your own requests. By default it serves\n\
         private jobs only — public/shared jobs run on local models, never your paid key.\n\
         Do not enable sharing for this provider unless your provider terms allow others to\n\
         use capacity from your account. Hydra does not authorize sharing, reselling, leasing,\n\
         transferring, sublicensing, or pooling third-party API access in violation of\n\
         provider terms."
    );
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
    // Vault passphrase: env (automation) or no-echo prompt.
    let passphrase = std::env::var("HYDRA_VAULT_PASSPHRASE")
        .unwrap_or_else(|_| rpassword::prompt_password("Vault passphrase: ").unwrap_or_default());

    let worker_id = worker_core::identity::machine_worker_id();
    let url = worker_core::worker_run::resolve_coordinator_url(None, &cfg);
    println!("Worker '{worker_id}' ({:?}) connecting to {url}.", cfg.execution_mode);

    // CLI and the desktop app share this exact run path (see worker_core::worker_run).
    let status = worker_core::worker_run::RunStatus::new();
    let params = worker_core::worker_run::RunParams {
        config: cfg,
        passphrase,
        coordinator_url: None,
        join_token: None,
    };
    // Ignore broken-pipe on these final writes (parent may have closed our stdout).
    use std::io::Write;
    match worker_core::worker_run::build_and_run(params, status).await {
        Ok(()) => {
            let _ = writeln!(std::io::stdout(), "Disconnected.");
        }
        Err(e) => {
            let _ = writeln!(std::io::stderr(), "transport error: {e}");
        }
    }
}
