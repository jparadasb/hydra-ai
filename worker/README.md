# worker — hydra-ai worker node

Rust workspace for the local AI execution gateway.

## Crates

| crate | what |
|-------|------|
| `worker-core` | adapters, token vault, gateway (privacy + limits + usage), registration, runtime detect |
| `worker-cli`  | `hydra-worker` headless CLI |
| `worker-tauri`| command layer the desktop UI calls (returns fingerprints, never tokens) |

## Build & test

```sh
cargo test --workspace          # all unit + integration tests
cargo build -p worker-cli       # the hydra-worker binary
```

Secret storage defaults to an encrypted local file (ChaCha20-Poly1305 + Argon2id, `0600`).
Build with `--features worker-core/os-keychain` to use the OS keychain (Secret Service /
Keychain / Credential Manager) instead — requires platform crypto libs.

## CLI quickstart

```sh
export HYDRA_VAULT_PASSPHRASE=...        # or you'll be prompted (no-echo)
hydra-worker init --mode both            # local / provider / both
HYDRA_PROVIDER_TOKEN=sk-... hydra-worker provider add openai   # or prompted
hydra-worker provider test openai        # validates against the API
hydra-worker usage                       # per-provider/model table
hydra-worker run                         # prints the (secret-free) registration payload
```

The token is read from a no-echo prompt or env, stored encrypted, and only ever shown as a
masked fingerprint (`sk-...abcd`). It never appears in argv, logs, config, or the
registration payload.

## Remaining integration

* **Coordinator transport** (`worker-core::coordinator_client`): persistent Phoenix Channel
  client that joins, sends the registration payload, receives leases, runs them through
  `Gateway::execute`, and returns results. The payload and gateway are done and tested; this
  is the socket wiring.
* **Desktop app shell** (`worker-tauri` + `ui/`): the Tauri runtime + web frontend wrapping
  `commands::Commands`. The command layer is done and tested; this adds the webkit shell.
