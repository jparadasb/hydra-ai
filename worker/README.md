# worker — hydra-ai worker node

Rust workspace for the local AI execution gateway.

## Crates

| crate | what |
|-------|------|
| `worker-core` | adapters (OpenAI-compat/Anthropic/Gemini external; Ollama/llama.cpp/vLLM local), token vault, gateway (privacy + limits + usage), registration, runtime detect |
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
HYDRA_PROVIDER_TOKEN=sk-... hydra-worker provider add openai   # paste a key, or:
hydra-worker provider login gemini       # browser sign-in (Google / Code Assist free tier)
hydra-worker provider login openai       # browser sign-in with ChatGPT (uses the ChatGPT backend)
hydra-worker provider test openai        # validates against the API
hydra-worker usage                       # per-provider/model table
hydra-worker run                         # connect to the coordinator and process leased jobs
```

A pasted token is read from a no-echo prompt or env, stored encrypted, and only ever shown as a
masked fingerprint (`sk-...abcd`). `provider login` runs a PKCE OAuth flow in the browser (on a
headless box it prints the URL and accepts the pasted redirect) and stores the OAuth credential
in the vault. Nothing — key or OAuth token — appears in argv, logs, config, or the registration
payload.

## Desktop app

`worker-app` (Tauri 2) + `ui/` wrap the tested `commands::Commands` layer: unlock the vault,
choose mode, add/sign-in providers, set routing, watch run status (coordinator, worker id,
jobs processed/failed, last error). Build with `cargo tauri dev` from `crates/worker-app` (needs
the platform WebView deps). The command layer never returns a raw token — only fingerprints.
