//! Machine-derived worker identity + an on-disk Ed25519 device keypair.
//!
//! The `worker_id` is derived from stable machine characteristics (a SHA-256 over host name,
//! OS/arch, CPU brand, and a persistent machine-id when present), so the same box always
//! presents the same identity with **no configuration**. The id is *not* a secret — anyone
//! can recompute it; it only names the worker.
//!
//! Authentication is the Ed25519 **device key**: generated locally on first run, stored
//! `0600`, and never transmitted. The worker proves ownership by signing `worker_id|ts|nonce`;
//! the coordinator verifies the signature against the public key it pinned on first contact
//! (trust-on-first-use). The private key never leaves the machine — same rule as provider
//! tokens.

use std::path::{Path, PathBuf};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

/// Low-entropy, stable per-machine fingerprint material. NOT secret.
fn fingerprint_material() -> String {
    let host = sysinfo::System::host_name().unwrap_or_default();
    let os_name = sysinfo::System::name().unwrap_or_default();
    let mut sys = sysinfo::System::new();
    sys.refresh_cpu_usage();
    let cpu = sys
        .cpus()
        .first()
        .map(|c| c.brand().trim().to_string())
        .unwrap_or_default();
    let cpu_count = sys.cpus().len();
    let machine_id = read_machine_id().unwrap_or_default();
    format!(
        "{host}|{os_name}|{arch}|{cpu}|{cpu_count}|{machine_id}",
        arch = std::env::consts::ARCH,
    )
}

/// Persistent OS machine id where available (Linux/systemd, dbus). Empty elsewhere — the other
/// fingerprint bits still distinguish the machine.
fn read_machine_id() -> Option<String> {
    for p in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
        if let Ok(s) = std::fs::read_to_string(p) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
    }
    None
}

/// Derive the stable `worker-<hex>` id from this machine's fingerprint.
pub fn machine_worker_id() -> String {
    let digest = Sha256::digest(fingerprint_material().as_bytes());
    let hex: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("worker-{hex}")
}

/// The signed authentication challenge a worker presents on connect. All non-secret: the
/// signature proves possession of the private key without revealing it.
#[derive(Debug, Clone)]
pub struct AuthParams {
    pub worker_id: String,
    /// Base64 Ed25519 public key (32 bytes).
    pub pubkey: String,
    /// Unix seconds; the coordinator rejects stale timestamps (replay window).
    pub ts: i64,
    pub nonce: String,
    /// Base64 Ed25519 signature (64 bytes) over [`auth_message`].
    pub sig: String,
}

/// Canonical message that gets signed. Must match the coordinator's reconstruction exactly.
pub fn auth_message(worker_id: &str, ts: i64, nonce: &str) -> String {
    format!("{worker_id}|{ts}|{nonce}")
}

/// An Ed25519 device key, loaded from disk or freshly generated.
pub struct DeviceKey {
    signing: SigningKey,
}

impl DeviceKey {
    /// Default key path under the OS config dir (`.../hydra/worker/worker.key`).
    pub fn default_path() -> PathBuf {
        directories::ProjectDirs::from("ai", "hydra", "worker")
            .map(|d| d.config_dir().join("worker.key"))
            .unwrap_or_else(|| PathBuf::from(".hydra").join("worker.key"))
    }

    /// Load the key at `path`, or generate + persist a new one (file mode `0600`).
    pub fn load_or_create(path: &Path) -> Result<Self> {
        if let Ok(contents) = std::fs::read_to_string(path) {
            let raw = B64
                .decode(contents.trim())
                .map_err(|e| Error::Other(format!("device key decode: {e}")))?;
            let bytes: [u8; 32] = raw
                .try_into()
                .map_err(|_| Error::Other("device key: bad length".into()))?;
            return Ok(Self {
                signing: SigningKey::from_bytes(&bytes),
            });
        }
        let seed: [u8; 32] = rand::random();
        let signing = SigningKey::from_bytes(&seed);
        write_secure(path, &B64.encode(seed))?;
        Ok(Self { signing })
    }

    /// Base64 public key.
    pub fn public_key_b64(&self) -> String {
        B64.encode(self.signing.verifying_key().to_bytes())
    }

    /// Base64 signature over `msg`.
    pub fn sign_b64(&self, msg: &[u8]) -> String {
        B64.encode(self.signing.sign(msg).to_bytes())
    }

    /// Build a fresh signed [`AuthParams`] for `worker_id`.
    pub fn auth_params(&self, worker_id: &str) -> AuthParams {
        let ts = now_unix();
        let nonce = B64.encode(rand::random::<[u8; 12]>());
        let sig = self.sign_b64(auth_message(worker_id, ts, &nonce).as_bytes());
        AuthParams {
            worker_id: worker_id.to_string(),
            pubkey: self.public_key_b64(),
            ts,
            nonce,
            sig,
        }
    }
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Write `data` to `path`, creating parents, with `0600` perms on Unix.
fn write_secure(path: &Path, data: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error::Other(format!("key dir: {e}")))?;
    }
    std::fs::write(path, data).map_err(|e| Error::Other(format!("key write: {e}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| Error::Other(format!("key chmod: {e}")))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    #[test]
    fn worker_id_is_stable_and_prefixed() {
        let a = machine_worker_id();
        let b = machine_worker_id();
        assert_eq!(a, b);
        assert!(a.starts_with("worker-"));
        assert_eq!(a.len(), "worker-".len() + 16);
    }

    #[test]
    fn key_round_trips_and_signature_verifies() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("worker.key");

        let key = DeviceKey::load_or_create(&path).unwrap();
        let pub1 = key.public_key_b64();

        // Reload from disk -> same key.
        let key2 = DeviceKey::load_or_create(&path).unwrap();
        assert_eq!(pub1, key2.public_key_b64());

        // Signature over the canonical message verifies under the public key.
        let auth = key.auth_params("worker-abc");
        let msg = auth_message(&auth.worker_id, auth.ts, &auth.nonce);
        let pk_bytes: [u8; 32] = B64.decode(&auth.pubkey).unwrap().try_into().unwrap();
        let sig_bytes: [u8; 64] = B64.decode(&auth.sig).unwrap().try_into().unwrap();
        let vk = VerifyingKey::from_bytes(&pk_bytes).unwrap();
        assert!(vk
            .verify(msg.as_bytes(), &Signature::from_bytes(&sig_bytes))
            .is_ok());

        // A tampered message fails.
        assert!(vk
            .verify(b"worker-abc|0|x", &Signature::from_bytes(&sig_bytes))
            .is_err());
    }

    #[cfg(unix)]
    #[test]
    fn key_file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("worker.key");
        DeviceKey::load_or_create(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
