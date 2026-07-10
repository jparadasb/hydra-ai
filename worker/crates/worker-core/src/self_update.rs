//! In-place self-update for the headless `hydra-worker` binary.
//!
//! Workers run as a long-lived systemd service on remote hosts; updating them by rebuilding
//! from source and copying by hand is painful. CI publishes a per-target binary to a rolling
//! `edge` prerelease on every push to `main` (and to permanent `v*` releases), each alongside
//! a `<asset>.sha256` checksum. This module downloads the matching asset and atomically swaps
//! the running executable.
//!
//! **Change detection is by content hash, never version.** Every `edge` build reports the same
//! `0.1.0`, so we compare the published `.sha256` against the hash of the current executable and
//! only swap when they differ.
//!
//! **Integrity, not authenticity.** The checksum is fetched over the same HTTPS channel as the
//! binary, so it guards against a truncated/corrupted download — not against a compromised
//! release. There is no code signing here (the desktop app uses Tauri's signed updater instead).

use std::io::Read;
use std::path::{Path, PathBuf};

use futures_util::StreamExt;
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

/// `owner/repo` whose GitHub releases host the worker binaries.
pub const DEFAULT_REPO: &str = "jparadasb/hydra-ai";

/// Which release to update from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Channel {
    /// The rolling `edge` prerelease (newest build of `main`). Default.
    Edge,
    /// The newest permanent `v*` release (`releases/latest`).
    Latest,
    /// A specific tag, e.g. `v0.2.0`.
    Tag(String),
}

impl Channel {
    /// Parse the CLI `--channel` value: `edge` / `latest` / anything else = a tag.
    pub fn parse(s: &str) -> Channel {
        match s {
            "edge" => Channel::Edge,
            "latest" => Channel::Latest,
            other => Channel::Tag(other.to_string()),
        }
    }
}

/// Inputs to [`run_update`].
#[derive(Debug, Clone)]
pub struct UpdateOptions {
    pub channel: Channel,
    /// Override the download base URL (expects `<base>/<asset>` and `<base>/<asset>.sha256`).
    /// Bypasses `channel`/`repo`. For mirrors and tests.
    pub base_url: Option<String>,
    /// Only report whether an update is available; never swap.
    pub check_only: bool,
    /// After download, run the new binary with `--version` to prove it loads before swapping.
    /// Disabled in tests that use non-executable fixtures.
    pub verify_exec: bool,
    /// Repo to source releases from (defaults to [`DEFAULT_REPO`]).
    pub repo: String,
}

impl Default for UpdateOptions {
    fn default() -> Self {
        Self {
            channel: Channel::Edge,
            base_url: None,
            check_only: false,
            verify_exec: true,
            repo: DEFAULT_REPO.to_string(),
        }
    }
}

/// Result of an update run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateOutcome {
    /// The running binary already matches the published asset.
    UpToDate { sha256: String },
    /// `check_only`: an update is available (the running hash differs from `remote`, which is
    /// `None` when the release publishes no `.sha256`).
    UpdateAvailable {
        current: String,
        remote: Option<String>,
    },
    /// The binary was replaced. `old`/`new` are hex sha256 of the previous and new executables.
    Updated {
        old: String,
        new: String,
        path: PathBuf,
    },
}

/// Human build identity for `--version`, e.g. `0.1.0 (abc1234)` or `0.1.0 (dev)`.
///
/// The commit comes from `HYDRA_BUILD_SHA`, exported by CI at build time; a local `cargo build`
/// has no such env, so it reports `(dev)`.
pub fn build_version() -> String {
    let ver = env!("CARGO_PKG_VERSION");
    match option_env!("HYDRA_BUILD_SHA") {
        Some(sha) if !sha.is_empty() => format!("{ver} ({})", &sha[..sha.len().min(7)]),
        _ => format!("{ver} (dev)"),
    }
}

/// The CI target triple for the host this binary was compiled for. Errors on any platform we
/// don't publish a prebuilt binary for.
pub fn current_target() -> Result<&'static str> {
    // Order matters: musl must be checked before the generic linux+x86_64 arm.
    if cfg!(all(
        target_os = "linux",
        target_arch = "x86_64",
        target_env = "musl"
    )) {
        Ok("x86_64-unknown-linux-musl")
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Ok("x86_64-unknown-linux-gnu")
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Ok("aarch64-apple-darwin")
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        Ok("x86_64-apple-darwin")
    } else if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Ok("x86_64-pc-windows-msvc")
    } else {
        Err(Error::Other(
            "self-update: no prebuilt hydra-worker binary for this platform".to_string(),
        ))
    }
}

/// Published asset name for a target, e.g. `hydra-worker-x86_64-unknown-linux-gnu`
/// (`…-msvc.exe` on Windows).
pub fn asset_name(target: &str) -> String {
    if target.contains("windows") {
        format!("hydra-worker-{target}.exe")
    } else {
        format!("hydra-worker-{target}")
    }
}

/// Base URL (no trailing slash) the asset + its `.sha256` sit under, for a channel.
pub fn asset_base_url(channel: &Channel, repo: &str) -> String {
    match channel {
        Channel::Edge => format!("https://github.com/{repo}/releases/download/edge"),
        // GitHub resolves `releases/latest/download/<asset>` to the newest non-prerelease.
        Channel::Latest => format!("https://github.com/{repo}/releases/latest/download"),
        Channel::Tag(tag) => format!("https://github.com/{repo}/releases/download/{tag}"),
    }
}

/// Streamed sha256 (lowercase hex) of a file on disk.
pub fn sha256_hex_of_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).map_err(io_err)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf).map_err(io_err)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

/// Extract the hash from a `sha256sum`-format line (`<64 hex>  <name>`) or a bare hash. Returns
/// `None` if the first token isn't 64 lowercase hex chars.
pub fn parse_sha256_file(s: &str) -> Option<String> {
    let token = s.split_whitespace().next()?.to_lowercase();
    if token.len() == 64 && token.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(token)
    } else {
        None
    }
}

/// Download the channel's asset and swap the running executable when it differs.
///
/// `exe_path` must be the resolved (canonicalized) path of the executable to replace.
pub async fn run_update(
    client: &reqwest::Client,
    exe_path: &Path,
    opts: &UpdateOptions,
) -> Result<UpdateOutcome> {
    let target = current_target()?;
    let asset = asset_name(target);
    let base = match &opts.base_url {
        Some(u) => u.trim_end_matches('/').to_string(),
        None => asset_base_url(&opts.channel, &opts.repo),
    };
    let asset_url = format!("{base}/{asset}");
    let sha_url = format!("{asset_url}.sha256");

    let exe_dir = exe_path
        .parent()
        .ok_or_else(|| Error::Other("self-update: executable has no parent directory".into()))?;
    let partial = exe_dir.join(".hydra-worker.partial");
    let dotold = exe_dir.join(".hydra-worker.old");
    // Clean up debris from a prior interrupted run so it can't be mistaken for anything.
    let _ = std::fs::remove_file(&partial);
    let _ = std::fs::remove_file(&dotold);

    let current = sha256_hex_of_file(exe_path)?;

    // Fetch the published checksum (tiny). 404 => this release has none; fall back to hashing a
    // full download.
    let remote_sha = fetch_remote_sha(client, &sha_url).await?;

    if let Some(remote) = &remote_sha {
        if remote == &current {
            return Ok(UpdateOutcome::UpToDate { sha256: current });
        }
        if opts.check_only {
            return Ok(UpdateOutcome::UpdateAvailable {
                current,
                remote: Some(remote.clone()),
            });
        }
    }

    // check_only with no published checksum: download to a temp file, hash, compare, discard.
    if opts.check_only {
        let tmp = std::env::temp_dir().join(".hydra-worker.check");
        let _ = std::fs::remove_file(&tmp);
        let dl = download_to(client, &asset_url, &tmp).await?;
        let _ = std::fs::remove_file(&tmp);
        return if dl == current {
            Ok(UpdateOutcome::UpToDate { sha256: current })
        } else {
            Ok(UpdateOutcome::UpdateAvailable {
                current,
                remote: None,
            })
        };
    }

    // Download next to the target (same filesystem, so the final rename is atomic). Surface a
    // permission problem here, before spending bandwidth.
    match std::fs::File::create(&partial) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err(Error::Other(format!(
                "self-update: cannot write {} (re-run as root: sudo hydra-worker update)",
                exe_dir.display()
            )));
        }
        Err(e) => return Err(io_err(e)),
    }

    let downloaded = download_to(client, &asset_url, &partial).await.inspect_err(|_| {
        let _ = std::fs::remove_file(&partial);
    })?;

    // When a checksum was published, the download must match it exactly.
    if let Some(remote) = &remote_sha {
        if &downloaded != remote {
            let _ = std::fs::remove_file(&partial);
            return Err(Error::Other(format!(
                "self-update: checksum mismatch (expected {remote}, got {downloaded}); aborted"
            )));
        }
    }

    // No published checksum and the bytes match what we already run: nothing to do.
    if downloaded == current {
        let _ = std::fs::remove_file(&partial);
        return Ok(UpdateOutcome::UpToDate { sha256: current });
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&partial, std::fs::Permissions::from_mode(0o755)).map_err(io_err)?;
    }

    if opts.verify_exec {
        sanity_check_exec(&partial)?;
    }

    swap_into_place(&partial, exe_path, &dotold)?;

    Ok(UpdateOutcome::Updated {
        old: current,
        new: downloaded,
        path: exe_path.to_path_buf(),
    })
}

/// GET `<asset>.sha256`. `Ok(Some(hash))` on 200, `Ok(None)` on 404, error otherwise.
async fn fetch_remote_sha(client: &reqwest::Client, url: &str) -> Result<Option<String>> {
    let resp = client.get(url).send().await?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !resp.status().is_success() {
        return Err(Error::ProviderStatus {
            status: resp.status().as_u16(),
            body: format!("fetching {url}"),
        });
    }
    let text = resp.text().await?;
    match parse_sha256_file(&text) {
        Some(h) => Ok(Some(h)),
        None => Err(Error::Other(format!("self-update: malformed checksum at {url}"))),
    }
}

/// Stream an asset to `dest`, returning its sha256 (lowercase hex). Non-2xx is an error.
async fn download_to(client: &reqwest::Client, url: &str, dest: &Path) -> Result<String> {
    use std::io::Write;

    let resp = client.get(url).send().await?;
    if !resp.status().is_success() {
        return Err(Error::ProviderStatus {
            status: resp.status().as_u16(),
            body: format!("downloading {url}"),
        });
    }

    let mut file = std::fs::File::create(dest).map_err(io_err)?;
    let mut hasher = Sha256::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let bytes = chunk?;
        hasher.update(&bytes);
        file.write_all(&bytes).map_err(io_err)?;
    }
    file.flush().map_err(io_err)?;
    Ok(hex(&hasher.finalize()))
}

/// Run `<candidate> --version` to prove it loads. A clap binary without the flag exits 2 with a
/// usage error; that still proves the binary is a runnable executable, so accept it (matters for
/// downgrades to releases that predate `--version`). Only a spawn failure — e.g. a glibc/arch
/// mismatch — is fatal.
fn sanity_check_exec(candidate: &Path) -> Result<()> {
    match std::process::Command::new(candidate).arg("--version").output() {
        Ok(out) if out.status.success() || out.status.code() == Some(2) => Ok(()),
        Ok(out) => Err(Error::Other(format!(
            "self-update: downloaded binary failed to run (exit {:?}); aborted",
            out.status.code()
        ))),
        Err(e) => Err(Error::Other(format!(
            "self-update: downloaded binary is not executable on this host ({e}); aborted"
        ))),
    }
}

/// Replace `exe_path` with `staged`. Atomic on unix. On Windows a running exe can't be renamed
/// over, so move it aside first.
fn swap_into_place(staged: &Path, exe_path: &Path, dotold: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        std::fs::rename(exe_path, dotold).map_err(io_err)?;
        if let Err(e) = std::fs::rename(staged, exe_path) {
            // Roll back so we don't leave the host without a binary.
            let _ = std::fs::rename(dotold, exe_path);
            return Err(io_err(e));
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = dotold;
        std::fs::rename(staged, exe_path).map_err(io_err)
    }
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn io_err(e: std::io::Error) -> Error {
    Error::Other(format!("self-update io: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn current_target_is_a_known_triple() {
        let t = current_target().expect("host must be a supported target under test");
        assert!([
            "x86_64-unknown-linux-gnu",
            "x86_64-unknown-linux-musl",
            "aarch64-apple-darwin",
            "x86_64-apple-darwin",
            "x86_64-pc-windows-msvc",
        ]
        .contains(&t));
    }

    #[test]
    fn asset_name_adds_exe_only_for_windows() {
        assert_eq!(
            asset_name("x86_64-unknown-linux-gnu"),
            "hydra-worker-x86_64-unknown-linux-gnu"
        );
        assert_eq!(
            asset_name("x86_64-pc-windows-msvc"),
            "hydra-worker-x86_64-pc-windows-msvc.exe"
        );
    }

    #[test]
    fn asset_base_url_per_channel() {
        assert_eq!(
            asset_base_url(&Channel::Edge, "o/r"),
            "https://github.com/o/r/releases/download/edge"
        );
        assert_eq!(
            asset_base_url(&Channel::Latest, "o/r"),
            "https://github.com/o/r/releases/latest/download"
        );
        assert_eq!(
            asset_base_url(&Channel::Tag("v0.2.0".into()), "o/r"),
            "https://github.com/o/r/releases/download/v0.2.0"
        );
    }

    #[test]
    fn parse_sha256_accepts_sha256sum_format_and_bare_hash() {
        let h = "a".repeat(64);
        assert_eq!(parse_sha256_file(&h), Some(h.clone()));
        assert_eq!(
            parse_sha256_file(&format!("{h}  hydra-worker-x86_64-unknown-linux-gnu\n")),
            Some(h.clone())
        );
        assert_eq!(parse_sha256_file(&format!("{}\n", "A".repeat(64))), Some(h));
        assert_eq!(parse_sha256_file("not a hash"), None);
        assert_eq!(parse_sha256_file(&"a".repeat(63)), None);
        assert_eq!(parse_sha256_file(""), None);
    }

    // ---- integration: wiremock serves a fake asset + checksum into a tempdir --------------

    fn write_exe(dir: &Path, contents: &[u8]) -> PathBuf {
        let p = dir.join("hydra-worker");
        std::fs::write(&p, contents).unwrap();
        p
    }

    fn opts(base: &str) -> UpdateOptions {
        UpdateOptions {
            channel: Channel::Edge,
            base_url: Some(base.to_string()),
            check_only: false,
            verify_exec: false,
            repo: DEFAULT_REPO.to_string(),
        }
    }

    async fn mock_asset(server: &MockServer, body: &[u8], sha: Option<&str>) {
        let asset = asset_name(current_target().unwrap());
        Mock::given(method("GET"))
            .and(path(format!("/{asset}")))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(body.to_vec()))
            .mount(server)
            .await;
        let sha_resp = match sha {
            Some(s) => ResponseTemplate::new(200).set_body_string(format!("{s}  {asset}\n")),
            None => ResponseTemplate::new(404),
        };
        Mock::given(method("GET"))
            .and(path(format!("/{asset}.sha256")))
            .respond_with(sha_resp)
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn up_to_date_skips_binary_download() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"current-binary");
        let cur = sha256_hex_of_file(&exe).unwrap();

        let asset = asset_name(current_target().unwrap());
        // Checksum matches; the binary endpoint must never be hit.
        Mock::given(method("GET"))
            .and(path(format!("/{asset}.sha256")))
            .respond_with(ResponseTemplate::new(200).set_body_string(format!("{cur}  {asset}\n")))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path(format!("/{asset}")))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"never".to_vec()))
            .expect(0)
            .mount(&server)
            .await;

        let out = run_update(&reqwest::Client::new(), &exe, &opts(&server.uri()))
            .await
            .unwrap();
        assert_eq!(out, UpdateOutcome::UpToDate { sha256: cur });
    }

    #[tokio::test]
    async fn check_mode_reports_available_and_leaves_file() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"old");
        let new_sha = sha256_hex_of_file(&{
            let p = dir.path().join("new-ref");
            std::fs::write(&p, b"new").unwrap();
            p
        })
        .unwrap();
        mock_asset(&server, b"new", Some(&new_sha)).await;

        let mut o = opts(&server.uri());
        o.check_only = true;
        let out = run_update(&reqwest::Client::new(), &exe, &o).await.unwrap();
        match out {
            UpdateOutcome::UpdateAvailable { remote, .. } => assert_eq!(remote, Some(new_sha)),
            other => panic!("expected UpdateAvailable, got {other:?}"),
        }
        assert_eq!(std::fs::read(&exe).unwrap(), b"old");
    }

    #[tokio::test]
    async fn full_update_swaps_binary() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"old-binary");
        let new_sha = {
            let p = dir.path().join("new-ref");
            std::fs::write(&p, b"new-binary-contents").unwrap();
            sha256_hex_of_file(&p).unwrap()
        };
        mock_asset(&server, b"new-binary-contents", Some(&new_sha)).await;

        let out = run_update(&reqwest::Client::new(), &exe, &opts(&server.uri()))
            .await
            .unwrap();
        match out {
            UpdateOutcome::Updated { new, .. } => assert_eq!(new, new_sha),
            other => panic!("expected Updated, got {other:?}"),
        }
        assert_eq!(std::fs::read(&exe).unwrap(), b"new-binary-contents");
        assert!(!dir.path().join(".hydra-worker.partial").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&exe).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
    }

    #[tokio::test]
    async fn checksum_mismatch_aborts_and_preserves_exe() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"old-binary");
        // Advertise a checksum that the served bytes don't satisfy.
        mock_asset(&server, b"tampered-bytes", Some(&"b".repeat(64))).await;

        let err = run_update(&reqwest::Client::new(), &exe, &opts(&server.uri()))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("checksum mismatch"));
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
        assert!(!dir.path().join(".hydra-worker.partial").exists());
    }

    #[tokio::test]
    async fn missing_checksum_falls_back_to_full_download() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"old-binary");
        mock_asset(&server, b"fresh-binary", None).await; // .sha256 -> 404

        let out = run_update(&reqwest::Client::new(), &exe, &opts(&server.uri()))
            .await
            .unwrap();
        assert!(matches!(out, UpdateOutcome::Updated { .. }));
        assert_eq!(std::fs::read(&exe).unwrap(), b"fresh-binary");
    }

    #[tokio::test]
    async fn asset_not_found_is_an_error() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let exe = write_exe(dir.path(), b"old-binary");
        // No mocks mounted -> every path 404s, including the asset.
        let asset = asset_name(current_target().unwrap());
        Mock::given(method("GET"))
            .and(path(format!("/{asset}.sha256")))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let err = run_update(&reqwest::Client::new(), &exe, &opts(&server.uri()))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("downloading"));
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
    }
}
