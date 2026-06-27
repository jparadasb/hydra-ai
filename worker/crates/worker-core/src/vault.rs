//! Token vault. The ONE place raw provider secrets exist in the worker.
//!
//! Storage precedence:
//!   1. OS keychain (feature `os-keychain`): Credential Manager / Keychain / Secret Service.
//!   2. Encrypted local file fallback: ChaCha20-Poly1305, key derived from a worker
//!      passphrase via Argon2id, file mode 0600.
//!
//! Invariants enforced here:
//!   * [`Secret`] never implements `Serialize` and its `Debug` prints `[REDACTED]`.
//!   * Only [`fingerprint`] is safe to display / log.
//!   * [`redact`] scrubs token-shaped substrings from arbitrary strings before logging.

use std::collections::HashMap;
use std::path::PathBuf;

use chacha20poly1305::aead::{Aead, KeyInit, OsRng};
use chacha20poly1305::{AeadCore, ChaCha20Poly1305, Key, Nonce};
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

const SERVICE: &str = "hydra-ai-worker";

/// A provider secret. Deliberately NOT `Serialize`. Debug/Display are redacted.
#[derive(Clone)]
pub struct Secret(String);

impl Secret {
    pub fn new(raw: impl Into<String>) -> Self {
        Secret(raw.into())
    }

    /// Borrow the raw secret. Call sites should be limited to building auth headers.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Masked, display-safe fingerprint, e.g. `sk-...abcd`.
    pub fn fingerprint(&self) -> String {
        fingerprint(&self.0)
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Secret({})", self.fingerprint())
    }
}

impl std::fmt::Display for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[REDACTED]")
    }
}

/// Build a masked fingerprint that keeps any leading provider prefix (up to a `-`) and the
/// last 4 chars: `sk-...abcd`, `AIza...wxyz`.
pub fn fingerprint(token: &str) -> String {
    let prefix: String = match token.split_once('-') {
        Some((p, _)) if p.len() <= 6 => format!("{p}-"),
        _ => token.chars().take(2).collect(),
    };
    let last4: String = token
        .chars()
        .rev()
        .take(4)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    format!("{prefix}...{last4}")
}

/// Scrub token-shaped substrings from a string so it is safe to log.
/// Single left-to-right scan; at each position the longest matching provider prefix wins,
/// then its trailing run of token chars is collapsed to `<prefix>...REDACTED`.
pub fn redact(s: &str) -> String {
    // Longest prefixes first so `sk-ant-` wins over `sk-`.
    const PREFIXES: &[&str] = &["sk-ant-", "sk-", "AIza", "gsk_", "or-", "r8_", "hf_"];
    let is_tok = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';

    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let rest = &s[i..];
        if let Some(p) = PREFIXES.iter().find(|p| rest.starts_with(**p)) {
            let after = &rest[p.len()..];
            let run = after.find(|c: char| !is_tok(c)).unwrap_or(after.len());
            if run > 0 {
                out.push_str(p);
                out.push_str("...REDACTED");
                i += p.len() + run;
                continue;
            }
        }
        // copy one char (handle UTF-8 boundaries)
        let ch = rest.chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Backend that persists secrets keyed by provider name.
pub trait SecretStore: Send + Sync {
    fn set(&self, provider: &str, secret: &Secret) -> Result<()>;
    fn get(&self, provider: &str) -> Result<Option<Secret>>;
    fn delete(&self, provider: &str) -> Result<()>;
}

/// The vault facade callers use. Wraps whichever [`SecretStore`] backend is active.
pub struct Vault {
    store: Box<dyn SecretStore>,
}

impl Vault {
    pub fn new(store: Box<dyn SecretStore>) -> Self {
        Self { store }
    }

    /// Add or replace a provider token.
    pub fn add(&self, provider: &str, secret: Secret) -> Result<()> {
        self.store.set(provider, &secret)
    }

    /// Fetch a provider token (for building auth headers only).
    pub fn get(&self, provider: &str) -> Result<Option<Secret>> {
        self.store.get(provider)
    }

    /// Remove a provider token.
    pub fn remove(&self, provider: &str) -> Result<()> {
        self.store.delete(provider)
    }

    /// Replace an existing token (rotate). Same as add; named for intent + audit.
    pub fn rotate(&self, provider: &str, new_secret: Secret) -> Result<()> {
        self.store.set(provider, &new_secret)
    }

    /// Display-safe fingerprint for a stored provider, if present.
    pub fn fingerprint(&self, provider: &str) -> Result<Option<String>> {
        Ok(self.get(provider)?.map(|s| s.fingerprint()))
    }
}

// ---------------------------------------------------------------------------
// Encrypted-file backend (always available fallback).
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
struct EncryptedBlob {
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    salt: Vec<u8>,
}

/// Encrypted local file store. AEAD = ChaCha20-Poly1305; key = Argon2id(passphrase, salt).
pub struct EncryptedFileStore {
    path: PathBuf,
    passphrase: String,
}

impl EncryptedFileStore {
    pub fn new(path: PathBuf, passphrase: String) -> Self {
        Self { path, passphrase }
    }

    /// Default location under the user's config dir.
    pub fn default_path() -> PathBuf {
        directories::ProjectDirs::from("ai", "hydra", "worker")
            .map(|d| d.config_dir().join("vault.bin"))
            .unwrap_or_else(|| PathBuf::from(".hydra-vault.bin"))
    }

    fn derive_key(&self, salt: &[u8]) -> Result<Key> {
        use argon2::Argon2;
        let mut key_bytes = [0u8; 32];
        Argon2::default()
            .hash_password_into(self.passphrase.as_bytes(), salt, &mut key_bytes)
            .map_err(|e| Error::Vault(format!("key derivation: {e}")))?;
        Ok(*Key::from_slice(&key_bytes))
    }

    fn load(&self) -> Result<HashMap<String, String>> {
        let bytes = match std::fs::read(&self.path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
            Err(e) => return Err(Error::Vault(format!("read: {e}"))),
        };
        let blob: EncryptedBlob =
            serde_json::from_slice(&bytes).map_err(|e| Error::Vault(format!("decode: {e}")))?;
        let key = self.derive_key(&blob.salt)?;
        let cipher = ChaCha20Poly1305::new(&key);
        let plaintext = cipher
            .decrypt(Nonce::from_slice(&blob.nonce), blob.ciphertext.as_ref())
            .map_err(|_| Error::Vault("decrypt failed (wrong passphrase?)".into()))?;
        serde_json::from_slice(&plaintext).map_err(|e| Error::Vault(format!("parse: {e}")))
    }

    fn save(&self, map: &HashMap<String, String>) -> Result<()> {
        let mut salt = [0u8; 16];
        OsRng.fill_bytes(&mut salt);
        let key = self.derive_key(&salt)?;
        let cipher = ChaCha20Poly1305::new(&key);
        let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
        let plaintext = serde_json::to_vec(map)?;
        let ciphertext = cipher
            .encrypt(&nonce, plaintext.as_ref())
            .map_err(|_| Error::Vault("encrypt failed".into()))?;
        let blob = EncryptedBlob {
            nonce: nonce.to_vec(),
            ciphertext,
            salt: salt.to_vec(),
        };
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::Vault(format!("mkdir: {e}")))?;
        }
        std::fs::write(&self.path, serde_json::to_vec(&blob)?)
            .map_err(|e| Error::Vault(format!("write: {e}")))?;
        Self::set_owner_only(&self.path)?;
        Ok(())
    }

    #[cfg(unix)]
    fn set_owner_only(path: &std::path::Path) -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms).map_err(|e| Error::Vault(format!("chmod: {e}")))
    }

    #[cfg(not(unix))]
    fn set_owner_only(_path: &std::path::Path) -> Result<()> {
        Ok(())
    }
}

impl SecretStore for EncryptedFileStore {
    fn set(&self, provider: &str, secret: &Secret) -> Result<()> {
        let mut map = self.load()?;
        map.insert(provider.to_string(), secret.expose().to_string());
        self.save(&map)
    }

    fn get(&self, provider: &str) -> Result<Option<Secret>> {
        Ok(self.load()?.get(provider).map(|s| Secret::new(s.clone())))
    }

    fn delete(&self, provider: &str) -> Result<()> {
        let mut map = self.load()?;
        map.remove(provider);
        self.save(&map)
    }
}

// ---------------------------------------------------------------------------
// OS keychain backend (feature-gated).
// ---------------------------------------------------------------------------

#[cfg(feature = "os-keychain")]
pub struct KeyringStore;

#[cfg(feature = "os-keychain")]
impl SecretStore for KeyringStore {
    fn set(&self, provider: &str, secret: &Secret) -> Result<()> {
        keyring::Entry::new(SERVICE, provider)
            .and_then(|e| e.set_password(secret.expose()))
            .map_err(|e| Error::Vault(e.to_string()))
    }

    fn get(&self, provider: &str) -> Result<Option<Secret>> {
        match keyring::Entry::new(SERVICE, provider).and_then(|e| e.get_password()) {
            Ok(pw) => Ok(Some(Secret::new(pw))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(Error::Vault(e.to_string())),
        }
    }

    fn delete(&self, provider: &str) -> Result<()> {
        match keyring::Entry::new(SERVICE, provider).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(Error::Vault(e.to_string())),
        }
    }
}

/// Build the best available vault. Prefers OS keychain; else encrypted file.
pub fn default_vault(_passphrase_for_fallback: impl Into<String>) -> Vault {
    #[cfg(feature = "os-keychain")]
    {
        let _ = _passphrase_for_fallback;
        return Vault::new(Box::new(KeyringStore));
    }
    #[cfg(not(feature = "os-keychain"))]
    {
        Vault::new(Box::new(EncryptedFileStore::new(
            EncryptedFileStore::default_path(),
            _passphrase_for_fallback.into(),
        )))
    }
}

// Keep SERVICE referenced even when the keychain feature is off.
#[cfg(not(feature = "os-keychain"))]
const _: &str = SERVICE;

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_vault() -> (Vault, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.bin");
        let store = EncryptedFileStore::new(path, "test-passphrase".into());
        (Vault::new(Box::new(store)), dir)
    }

    #[test]
    fn round_trip_add_get_rotate_remove() {
        let (vault, _d) = tmp_vault();
        vault.add("openai", Secret::new("sk-secret-AAAA")).unwrap();
        assert_eq!(
            vault.get("openai").unwrap().unwrap().expose(),
            "sk-secret-AAAA"
        );

        vault
            .rotate("openai", Secret::new("sk-rotated-BBBB"))
            .unwrap();
        assert_eq!(
            vault.get("openai").unwrap().unwrap().expose(),
            "sk-rotated-BBBB"
        );

        vault.remove("openai").unwrap();
        assert!(vault.get("openai").unwrap().is_none());
    }

    #[test]
    fn multiple_providers_isolated() {
        let (vault, _d) = tmp_vault();
        vault.add("openai", Secret::new("sk-aaaa1111")).unwrap();
        vault
            .add("anthropic", Secret::new("sk-ant-bbbb2222"))
            .unwrap();
        assert_eq!(
            vault.get("openai").unwrap().unwrap().expose(),
            "sk-aaaa1111"
        );
        assert_eq!(
            vault.get("anthropic").unwrap().unwrap().expose(),
            "sk-ant-bbbb2222"
        );
    }

    #[test]
    fn wrong_passphrase_fails_to_decrypt() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.bin");
        EncryptedFileStore::new(path.clone(), "right".into())
            .set("openai", &Secret::new("sk-xyz"))
            .unwrap();
        let wrong = EncryptedFileStore::new(path, "wrong".into());
        assert!(wrong.get("openai").is_err());
    }

    #[test]
    fn fingerprint_masks_token() {
        assert_eq!(fingerprint("sk-abcdefgh1234"), "sk-...1234");
        let fp = fingerprint("sk-ant-verylongsecret9999");
        assert!(fp.ends_with("9999") && fp.contains("..."));
        assert!(!fp.contains("verylongsecret"));
    }

    #[test]
    fn debug_and_display_never_leak() {
        let s = Secret::new("sk-supersecret-1234");
        assert!(!format!("{s:?}").contains("supersecret"));
        assert_eq!(format!("{s}"), "[REDACTED]");
    }

    #[test]
    fn redact_scrubs_known_prefixes() {
        let line = "auth failed using sk-ant-abc123def and AIzaSyXYZ key";
        let r = redact(line);
        assert!(!r.contains("abc123def"));
        assert!(!r.contains("AIzaSyXYZ"));
        assert!(r.contains("sk-ant-...REDACTED"));
        assert!(r.contains("AIza...REDACTED"));
    }
}
