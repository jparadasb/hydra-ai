# Scripts

Six hundred lines of shell lived here and under `coordinator/scripts/` and `worker/scripts/`
with nothing referencing them — not CI, not the README. That makes them indistinguishable from
abandoned code. They are useful, so here is what each one is for.

None of these run in CI. They all need a coordinator to talk to.

## Setup

| | |
|---|---|
| [`setup-opencode.sh`](setup-opencode.sh) | Point a CLI coding agent (opencode, or any OpenAI-compatible client via `--target env`) at a coordinator. Merges a `hydra` provider into opencode's config, stores the gateway key at mode 0600, and installs a 15-minute timer that refreshes the model list as workers come and go. |

`--url` is required. `uninstall` removes the timer, the cron entry and the key file.

```sh
scripts/setup-opencode.sh --url https://coordinator.example.com --key hydra_sk_...
scripts/setup-opencode.sh sync        # refresh the model list now
scripts/setup-opencode.sh uninstall
```

## Smoke tests

| | |
|---|---|
| [`../coordinator/scripts/curl_smoke.sh`](../coordinator/scripts/curl_smoke.sh) | Walks the coordinator's public endpoints with curl — health, models, a completion, the error shapes. The quickest "is this deployment alive and answering correctly". |
| [`../worker/scripts/test-worker-opencode.sh`](../worker/scripts/test-worker-opencode.sh) | End-to-end through the whole chain: opencode → coordinator `/v1` → WebSocket lease → worker → provider. Use it to prove a *worker* is really serving traffic, not just connected. |

## Load

Each drives a different layer, which is the point — they isolate where a slowdown is.

| | |
|---|---|
| [`../coordinator/scripts/stress.sh`](../coordinator/scripts/stress.sh) | General load against the `:4000` API. |
| [`../coordinator/scripts/stress_openai.sh`](../coordinator/scripts/stress_openai.sh) | The front door specifically: full round trips through `POST /v1/chat/completions`, including the wait on PubSub for the result. Exercises the path a real caller takes. |
| [`../coordinator/scripts/stress_jobs.sh`](../coordinator/scripts/stress_jobs.sh) | Job *intake* only — `Coordinator.submit_job/1`, i.e. the Repo insert plus the Oban enqueue plus the routing decision, with no worker round trip. Isolates database and scheduling cost from inference cost. |
| [`../coordinator/scripts/stress_jobs.exs`](../coordinator/scripts/stress_jobs.exs) | The same intake load as an Elixir script, run inside the release (`bin/coordinator eval`) where there is no HTTP job API to drive. |

Worth knowing before you read the results: the front door now has per-key rate and concurrency
ceilings (`HYDRA_RATE_LIMIT_PER_MINUTE`, `HYDRA_MAX_CONCURRENT_PER_KEY`). A load test that
starts returning `429` is being throttled, not failing — set them to `0` to measure raw
capacity.
