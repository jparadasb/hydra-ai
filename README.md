# hydra-ai

Distributed AI job network. A central **coordinator** leases jobs to **worker nodes**
running on users' machines. Each worker is a **local AI execution gateway**: it can run a
local model (Ollama / llama.cpp / LM Studio / vLLM) or call a user-owned external provider
(OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, custom OpenAI-compatible).

## Core rule

**Provider tokens never leave the worker.** The coordinator only ever sees capabilities and
usage metadata, and routes jobs by capability / privacy / trust / cost / policy. `Secret` is
non-serializable on the worker; the coordinator's `SecretGuard` strips/rejects any
secret-shaped payload. Asserted by tests on both sides.

## Layout

```
worker/        Rust worker node (workspace)
  crates/
    worker-core/   adapters, token vault, gateway (privacy+limits+usage), transport client
    worker-cli/    `hydra-worker` headless CLI
    worker-tauri/  desktop command layer (returns fingerprints, never tokens)
    worker-app/    Tauri 2 desktop shell (excluded from workspace; links system WebView)
  ui/              desktop frontend (mode / providers / privacy / usage)
coordinator/   Elixir / Phoenix coordinator (channels, privacy routing, Oban leasing, Ecto)
proto/         shared wire schemas (no secret fields; serde + Ecto validate against these)
```

## Privacy routing

| privacy     | eligible workers |
|-------------|------------------|
| public      | local-model and external-provider workers |
| private     | external only if the job permits it; otherwise local / org / internal |
| sensitive   | not external-provider by default (must have a local model) |
| local_only  | must not use an external provider |

Enforced on the coordinator (`Coordinator.Router`) **and** re-checked on the worker
(`worker-core::privacy`) — defense in depth.

## Build & test

```sh
cd worker && cargo test --workspace      # Rust: core, cli, tauri command layer
cd coordinator && mix test               # Elixir: routing, channel, durability + a live e2e
```

The Elixir suite launches the real `hydra-worker` binary, which connects over a WebSocket,
registers, is leased a job, runs it through the gateway, and returns a secret-free result.

## Run a worker

```sh
cd worker
cargo build -p worker-cli --release
export HYDRA_VAULT_PASSPHRASE=...                       # or be prompted (no-echo)
./target/release/hydra-worker init --mode both
HYDRA_PROVIDER_TOKEN=sk-... hydra-worker provider add openai
HYDRA_COORDINATOR_URL=wss://hydra.example.com hydra-worker run
```

Desktop app: `worker/crates/worker-app` (`cargo tauri dev`) — see its `SETUP.md` for the
WebView system deps.

### Where the coordinator URL comes from

The worker resolves which coordinator to connect to in this order (first wins):

1. `HYDRA_COORDINATOR_URL` environment variable (runtime)
2. `coordinator_url` in the worker's `config.json`
3. a URL **baked at build time** (see below)
4. built-in default `ws://127.0.0.1:4000`

Use `ws://` on a LAN/loopback and `wss://` for a public (tunneled) coordinator.

### Build-time worker configuration (ship a pre-pointed binary)

To hand someone a binary that already targets your coordinator — no env vars, no `init` — set
the values **in the build environment**; they are compiled into the binary via `option_env!`:

```sh
cd worker
HYDRA_COORDINATOR_URL=wss://hydra.example.com \
HYDRA_JOIN_TOKEN=<optional-fallback-shared-secret> \
  cargo build -p worker-cli --release
```

| build env var          | bakes in                                              | needed? |
|------------------------|-------------------------------------------------------|---------|
| `HYDRA_COORDINATOR_URL`| default coordinator URL (overridable at runtime)      | optional |
| `HYDRA_JOIN_TOKEN`     | fallback shared join token                             | optional — device auth is preferred |

Notes:
- **Device auth needs nothing baked.** The `worker_id` and Ed25519 device key are created at
  first `run` (see [Worker authentication](#worker-authentication)). A plain
  `cargo build -p worker-cli` already produces a working, self-enrolling worker.
- A baked value is a **default**, still overridable at runtime by the env var or `config.json`.
- Anything baked is recoverable from the binary (`strings`); only bake non-sensitive defaults
  (the URL) or a low-value fallback secret. Rotating a baked value means rebuilding.
- Pure-Rust build: Rust ≥ 1.80 + network for crates. No system crypto/SSL libs (rustls,
  `ed25519-dalek`, `sha2` are all pure Rust).

## Worker authentication

A worker connects with **just the coordinator URL** plus a self-issued identity — no token to
copy around:

- Its `worker_id` is derived from stable machine characteristics (same box ⇒ same id, zero
  config). The id is an identifier, **not** a secret.
- On first run it generates an **Ed25519 device key** (`0600`, never leaves the machine, same
  rule as provider tokens) and signs `worker_id|ts|nonce` on each connect.
- The coordinator verifies the signature and **pins the public key** to that `worker_id` on
  first contact (trust-on-first-use). Later connects must present the same key; a different
  key for an enrolled id is rejected, and a revoked key is refused.

Set `HYDRA_REQUIRE_DEVICE_AUTH=true` on the coordinator to reject any worker without a device
key (recommended once the coordinator is publicly reachable). An optional shared
`HYDRA_JOIN_TOKEN` is the fallback for non-device clients. Pinned keys live in the
`worker_keys` table; revoke a worker with `Coordinator.DeviceAuth.revoke(worker_id)`.

## Deploy the coordinator (Docker + Cloudflare Tunnel)

The stack is Postgres + the coordinator release + a [Cloudflare
Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) that
exposes it publicly with **no inbound ports opened on the host**.

```sh
cp .env.example .env        # set POSTGRES_PASSWORD, SECRET_KEY_BASE, TUNNEL_TOKEN
docker compose up -d --build
```

- `SECRET_KEY_BASE`: `openssl rand -base64 48` (or `mix phx.gen.secret`).
- `TUNNEL_TOKEN`: create a tunnel in the Cloudflare **Zero Trust → Networks → Tunnels**
  dashboard, copy its token, and route your public hostname to the service
  `http://coordinator:4000`.

The coordinator image (`coordinator/Dockerfile`) builds an Elixir release compiled against
**Postgres** (`DB_ADAPTER=postgres`), runs migrations on start (`Coordinator.Release.migrate/0`),
then serves the worker WebSocket on `:4000`. See `coordinator/README.md` for the
SQLite ↔ Postgres backend switch and `STATUS.md` for the overall build state.
```
docker compose logs -f coordinator     # watch migrations + boot
docker compose ps                       # postgres / coordinator / cloudflared
```
