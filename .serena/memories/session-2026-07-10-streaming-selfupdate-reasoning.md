# Session 2026-07-10 — token streaming, worker self-update, reasoning deltas

Three features shipped for the worker + coordinator, plus a deploy investigation left open. All merged to `main` and released.

## 1. End-to-end token streaming (commit `2d23bd1`, released ≤ v1.1.2)
Before: gateway SSE was fake — worker ran a blocking chat completion and the whole answer arrived as one delta at the end, so clients sat silent for the entire generation and the 60s default wait 504'd jobs the worker then finished anyway.

- **proto**: new `job_result_chunk.schema.json` (`job_id`, `seq`, `delta`).
- **worker**: adapters request `stream:true` (+ `stream_options.include_usage`); `StreamAssembly` (`adapters/openai_compatible.rs`) parses SSE incrementally, assembling content, tool-call fragments (by delta index), and the trailing usage chunk. Leased jobs push fire-and-forget `result_chunk` messages over the Phoenix channel; adapters without streaming fall back to the blocking call. `DeltaSink` type in `adapter.rs`.
- **coordinator**: per-job PubSub topic `job_chunks:<job_id>`. API stream path (`api_router.ex`) generates the job id up front, subscribes before submit, relays chunks as real content deltas, and suppresses the duplicate final-content frame. `WorkerSession.handle_chunk` sanitizes + broadcasts. Heartbeats now only fill silence.
- Also bumped `@default_timeout_ms` 60s → 300s; `scripts/setup-opencode.sh` writes `x-hydra-timeout-ms` header.

## 2. Worker self-update (commit `77a4936`, v1.1.3)
Goal: update workers without rebuild/scp.

- **CLI**: `hydra-worker update [--check] [--channel edge|latest|<tag>] [--url] [--restart]` in `worker-core/src/self_update.rs`. Change detection by **sha256, never version** (edge is always 0.1.0-ish): CI publishes `<asset>.sha256`; `--check` fetches only that. Atomic swap = download to `.partial` next to the canonicalized exe, verify checksum, chmod 755, sanity-exec `--version`, `fs::rename` over the running binary. Exit codes: 0 up-to-date/installed, 10 update-available, 1 error. `--version` now reports `X.Y.Z (sha)` via `option_env!("HYDRA_BUILD_SHA")`.
- **CI** (`worker.yml`): cli job embeds `HYDRA_BUILD_SHA=github.sha` and emits `<asset>.sha256`.
- **Desktop (Tauri) updater**: `tauri-plugin-updater` + `tauri-plugin-process`, `createUpdaterArtifacts: true`, endpoint `releases/latest/download/latest.json`, capabilities file `worker-app/capabilities/default.json`, UI check/install in `ui/main.js`. **Tagged `v*` only** (updater compares semver). Signing key lives at `~/.config/hydra/tauri-updater.key` (empty password); repo secrets `TAURI_SIGNING_PRIVATE_KEY` / `_PASSWORD` were set (via `gh secret set < file` — manual paste corrupts the 348-char key → "Missing comment in secret key"). Pubkey baked into `tauri.conf.json`.
- Registration payload gained optional `version` field (`registration.rs` + schema) for fleet visibility.
- **Verified in prod**: both CTs self-updated with `hydra-worker update --restart --channel latest` — one command, no pct push.

## 3. Reasoning/thinking token streaming (commit `fd5b4c5`, v1.1.4)
Qwen (and reasoning models) emit thinking in `reasoning_content`/`reasoning` deltas and the answer in `content`. Worker only forwarded `content`, so reasoning-heavy/short prompts streamed nothing and often returned empty.

- `job_result_chunk` + `JobResultChunk` gained `reasoning: bool` (default false → back-compat).
- `DeltaSink` now `Fn(&str, bool)`. `StreamAssembly.feed_line` parses `reasoning_content`/`reasoning`, forwards tagged, never folds into answer content.
- coordinator relays a reasoning chunk as a `reasoning_content` SSE delta (not `content`); reasoning chunks don't set `streamed?` (they're never the answer).
- **Proven working**: isolated local test (v1.1.4 worker + reasoning coordinator, real M40 backend) streamed **250 `reasoning_content` deltas**; unit tests pass both sides.

## OPEN ISSUE — prod coordinator not serving fd5b4c5
Through prod `hydra.lambdatauri.dev`, reasoning shows **0 deltas** and prod returns **empty across all models**, while the identical worker+coordinator source works locally and the M40 backend streams reasoning directly (400 deltas). So the break is the **prod coordinator pod**.

- Coordinator auto-deploys on push to main: `coordinator.yml` builds an OCIR image and `bump-fleet` updates the GitOps repo `jparadasb/lambdatauri-cluster-fleet` (`clusters/tauri/apps/hydra/deployment.yaml`), Flux reconciles. bump-fleet succeeded; fleet declares `hydra-coordinator:fd5b4c5` (correct reasoning image).
- Prod behavior says the pod hasn't effectively rolled out or is unhealthy (possible regression). **Could not reach the cluster from this WSL box**: no local kubeconfig, `tauri-control-plane` ssh alias not in this box's config (it's on the user's primary machine), proxmox has no kubectl, `192.168.10.79` is offline, no oci CLI.
- **To diagnose**: from a machine with the alias — `ssh tauri-control-plane kubectl -n hydra get pods -o wide`; `... describe deploy hydra-coordinator | grep -i image`; `... logs deploy/hydra-coordinator --tail=100`; `flux get kustomizations -A`. If the fd5b4c5 pod crash-loops, cause is env/DB/secret/health-probe (code runs clean locally); roll back the fleet image tag if needed.

## Environment notes
- Prod coordinator runs on OCI k8s (cluster `tauri`, ingress `204.216.109.199`), NOT the homelab. CT workers (Proxmox 206/209) connect out via `wss://hydra.lambdatauri.dev`.
- CTs both on **v1.1.4 (cfdfd36)** static musl. Update via `hydra-worker update --restart --channel latest` (see [[hydra-worker-ct-update]] in user memory).
- **Both CT 206 and 209 advertise `Qwen3.6-35B-A3B`, but 206 (RTX 3060, 12GB) can't actually serve the 35B model → returns empty when the coordinator routes Qwen there.** Separate follow-up: stop 206 advertising models it can't serve. M40 (209) is the real Qwen worker via lm_studio adapter (127.0.0.1:1234 → `hydra-lmproxy.socket` → llama-swap :9090).
- Non-stream Qwen/gemma return empty content with non-zero completion_tokens because output goes to `reasoning_content`, which the non-stream `oai_chat` path drops (only streaming forwards reasoning now).
- No local cargo — build the Rust worker in a `rust:1` docker container with a `hydra-cargo-cache` volume. Coordinator tests need `elixir:1.19` (repo requires `~> 1.19`).
