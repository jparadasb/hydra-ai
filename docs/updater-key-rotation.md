# Updater signing key: backup and rotation

The desktop app verifies every update against a single minisign public key pinned in
`worker/crates/worker-app/tauri.conf.json`. The private half lives only in the repo secrets
`TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.

That is one key, in one place, with no documented way back. **Losing it bricks in-app updates
for every installed desktop app**: builds still sign nothing the installed app trusts, and each
user has to download and install a new build by hand. Leaking it is worse — anyone holding it
can sign an update that installed apps will accept and run.

This file is the procedure. It cannot be automated away: both halves need someone with access
to the repo's secrets and to wherever the backup is kept.

## Back up the current key (do this first)

The private key is a short base64 blob. Store it somewhere that is not GitHub — a password
manager entry or an offline encrypted file — together with its password. Two copies, two
places; a backup that lives beside the original is not a backup.

Record with it:

- the matching **public** key (`plugins.updater.pubkey` in `tauri.conf.json`)
- the date it was generated
- who has access

## Rotating

Rotation is a two-release process, because an installed app only trusts the key it shipped
with. Skipping the first release orphans every existing install.

### 1. Generate the new key

```sh
# From a machine with the Tauri CLI. Choose a strong password; it becomes the second secret.
npm exec -- tauri signer generate -w ~/.config/hydra/updater-new.key
```

Back it up as above **before** it is used for anything.

### 2. Ship a release that still signs with the old key

Publish a normal `v*` release signed with the **current** key, whose only job is to get
installed. Once a user has that build, their app is running code you control and is ready to be
pointed at a new key.

### 3. Swap the public key and cut a second release

- Replace `plugins.updater.pubkey` in `tauri.conf.json` with the new public key.
- Replace the `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` repo
  secrets with the new private key and its password.
- Tag and release. This build is signed with the new key, and is verified by the app from
  step 2 — which still trusts the old one, and is what allows the handoff.

### 4. Confirm, then retire

Install the step-3 release on a machine running the step-2 build and take the update through
the in-app banner. Only once that works should the old private key be destroyed — and keep the
old **public** key in the backup record, so an old artifact's signature can still be identified
later.

## If the key is lost

There is no recovery. Publish a release signed with a new key, and tell users to download and
install it manually — the in-app updater cannot bridge the gap, because installed apps have no
reason to trust the new signature.

## What this does not cover

OS-level code signing — Apple notarization and Windows Authenticode — is a separate thing and
is still not configured, so Gatekeeper and SmartScreen warn on first run. It needs an Apple
Developer account and a Windows code-signing certificate; neither can be generated from the
repository.
