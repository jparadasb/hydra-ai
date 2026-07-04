# hydra-ai

Distributed AI job network. A central **coordinator** leases jobs to **worker nodes**
running on users' machines. Each worker is a **local AI execution gateway**: it can run a
local model (Ollama / llama.cpp / LM Studio / vLLM) or call a user-owned external provider
(OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, custom OpenAI-compatible).

Callers use it through an **OpenAI-compatible API** (`POST /v1/chat/completions`, `/v1/models`,
streaming) — see [OpenAI-compatible API](#openai-compatible-api). External providers can be
added with a pasted key **or a browser sign-in** (Gemini via Google, OpenAI via ChatGPT).

## Core rule

**Provider tokens never leave the worker.** The coordinator only ever sees capabilities and
usage metadata, and routes jobs by capability / privacy / trust / cost / policy. `Secret` is
non-serializable on the worker; the coordinator's `SecretGuard` strips/rejects any
secret-shaped payload. Asserted by tests on both sides.

## Provider terms & compliance

Hydra is a **community compute coordinator** for local and open-weight model sharing — not an
API resale platform, marketplace, or a way to pool provider quotas.

**Local compute is shareable. Commercial API keys are private by default.** An external
provider you configure (OpenAI, Anthropic, Gemini, …) is used **only for your own requests**:
by default it serves `private` jobs only, and public/shared jobs run on local/open-weight
models — your paid key is never used to answer arbitrary requesters. Sharing an external
provider with a trusted org/community is opt-in and off by default.

Hydra does **not** authorize users to share, resell, lease, transfer, sublicense, or pool
third-party API credentials or API capacity in violation of provider terms. Do not enable
external-provider sharing unless your provider terms allow others to use capacity from your
account. You are responsible for your own compliance with each provider's terms.

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

**Which levels a worker may accept is set by the admin, not the worker.** Every worker starts
public-only; an admin raises it per worker in `/admin/workers`. Whatever a worker declares for
itself is advisory and is overridden at registration (fail-safe). The coordinator also honors
the requested **model**: a request for `model: X` routes to a worker that actually serves `X`
(falling back to any capable worker if none do), and the worker runs that exact model.

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
HYDRA_PROVIDER_TOKEN=sk-... hydra-worker provider add openai   # paste a key, or:
hydra-worker provider login gemini                     # browser sign-in (Google / Code Assist)
hydra-worker provider login openai                     # browser sign-in with ChatGPT
HYDRA_COORDINATOR_URL=wss://hydra.example.com hydra-worker run
```

**Provider sign-in (`provider login`)** opens a browser (PKCE OAuth); on a headless box it
prints the URL and you paste the redirect back. Tokens are stored in the local vault, never
sent to the coordinator. `gemini` uses the Google Code Assist free tier; `openai` signs in
with ChatGPT and uses the ChatGPT backend directly (no platform API key/organization needed).
The desktop app exposes the same as **Sign in with ChatGPT / Google** buttons on the Providers
screen.

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

## OpenAI-compatible API

The coordinator's public front-door speaks the OpenAI API, so existing clients/SDKs work by
just pointing at it with a gateway key:

| endpoint | notes |
|----------|-------|
| `POST /v1/chat/completions` | `messages`, `model`, `max_tokens`, `temperature`, `tools`/`tool_choice` (function calling — works with agent clients like opencode); `stream: true` returns an SSE `chat.completion.chunk` stream ending in `[DONE]` |
| `GET /v1/models`, `GET /v1/models/{id}` | models currently servable by connected workers |
| `GET /health` | liveness (public) |
| `GET /openapi.json`, `GET /docs` | **API docs (public)** — OpenAPI 3 spec + Redoc page |

```sh
curl https://hydra.example.com/v1/chat/completions \
  -H "Authorization: Bearer hydra_sk_..." -H "content-type: application/json" \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"hello"}]}'
```

**Postman:** Import → Link → `https://hydra.example.com/openapi.json` generates the full
collection; set the bearer token and go. Authenticate with a gateway key (below) — never a
provider secret. An upstream provider error (e.g. a rate limit) is passed through with its real
status (`429`, …), not masked as a generic `502`.

## Admin console (`/admin`)

The coordinator serves an admin console alongside the front-door (GitHub-OAuth gated in prod,
open on loopback dev):

- **API keys** (`/admin`) — mint gateway keys that authorize callers of `POST /v1/chat/completions`.
  Each key's plaintext is shown **once** at creation; only its SHA-256 hash is stored (a DB or
  backup leak never yields a usable key). Keys are revocable. These are **not** provider tokens
  — they only gate who may submit jobs. Set `HYDRA_REQUIRE_API_TOKEN=true` so admin-issued keys
  alone gate the door even without a shared `HYDRA_API_TOKEN`.
- **Workers** (`/admin/workers`) — enrolled workers; grant each the job privacy levels it may
  accept (public / private / sensitive / local_only), applied to a connected worker
  immediately; revoke/restore its device key.
- **Dashboard** (`/admin/dashboard`) — connected workers vs pending/leased/done/failed jobs,
  with throughput charts.
- **Oban dashboard** (`/admin/oban`) — the real Oban Web UI for tracking jobs, queues, retries.

**Access is protected by GitHub OAuth in prod, and open on loopback dev.** To enable it:

1. Register a GitHub **OAuth app** with Authorization callback URL
   `<HYDRA_ADMIN_BASE_URL>/auth/github/callback` (e.g.
   `https://hydrai.lambdatauri.dev/auth/github/callback`).
2. Set `HYDRA_GITHUB_CLIENT_ID`, `HYDRA_GITHUB_CLIENT_SECRET`, `HYDRA_ADMIN_BASE_URL`, and
   `HYDRA_ADMIN_GITHUB_USERS` (comma-separated allowlist of GitHub logins). An empty allowlist
   admits nobody (fail closed).

Enforcement is on automatically in prod; set `HYDRA_ADMIN_AUTH=false` to open `/admin` without
login (never on a public tunnel). The OAuth access token is used once server-side to read the
user's login and is never persisted.

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

### Scaling to multiple replicas

Connected-worker state lives in a cluster-wide `Phoenix.Presence` backed by libcluster, so >1
coordinator replica presents one unified view (a worker connected to any replica shows on every
dashboard). On Kubernetes: a headless Service for peer discovery plus
`RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=<name>@<pod-ip>`, a shared `RELEASE_COOKIE`, and
`HYDRA_CLUSTER_SERVICE=<headless-svc>`. With no cluster env set it runs as a single node.
