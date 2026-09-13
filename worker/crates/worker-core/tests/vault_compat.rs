//! A vault written by an older build must still open.
//!
//! `EncryptedFileStore` derives its key with `Argon2::default()`, so the parameters come from
//! whatever version of the `argon2` crate is compiled in. If a future bump changes those
//! defaults, every existing `vault.bin` becomes undecryptable — and the failure is silent and
//! total: the user's provider tokens are simply gone, with no error that says why.
//!
//! The fixture here was written by a build using argon2 0.5. It is checked in so the next
//! person to bump that dependency finds out from a red test rather than from a user.

use worker_core::vault::{EncryptedFileStore, SecretStore};

const PASSPHRASE: &str = "old-vault-pass";
const PROVIDER: &str = "custom";
const TOKEN: &str = "sk-legacy-token-12345";

#[test]
fn a_vault_written_by_an_older_argon2_still_decrypts() {
    // Copied to a temp path: the store writes back on some operations and the fixture must
    // stay as it was written.
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("vault.bin");
    std::fs::copy(
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/vault-argon2-0.5.bin"
        ),
        &path,
    )
    .expect("copy fixture");

    let store = EncryptedFileStore::new(path, PASSPHRASE.to_string());

    let secret = store
        .get(PROVIDER)
        .expect("reading the vault should not error")
        .expect("the provider's token should still be in there");

    assert_eq!(
        secret.expose(),
        TOKEN,
        "a vault written by an older build no longer decrypts — check whether the argon2 \
         default parameters changed, because this breaks every existing install"
    );
}

#[test]
fn the_wrong_passphrase_does_not_open_it() {
    // The other half of the guarantee: the test above would also pass if decryption had
    // silently stopped checking anything.
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("vault.bin");
    std::fs::copy(
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/vault-argon2-0.5.bin"
        ),
        &path,
    )
    .expect("copy fixture");

    let store = EncryptedFileStore::new(path, "not-the-passphrase".to_string());

    match store.get(PROVIDER) {
        Err(_) => {}
        Ok(None) => {}
        Ok(Some(_)) => panic!("the vault opened with the wrong passphrase"),
    }
}
