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
cargo build -p worker-cli
export HYDRA_VAULT_PASSPHRASE=...                # or be prompted (no-echo)
./target/debug/hydra-worker init --mode both
HYDRA_PROVIDER_TOKEN=sk-... hydra-worker provider add openai
hydra-worker run                                 # connects to the coordinator, processes jobs
```

Desktop app: `worker/crates/worker-app` (`cargo tauri dev`) — see its `SETUP.md` for the
WebView system deps.

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
