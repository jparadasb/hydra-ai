# hydra-ai

Distributed AI job network. A central **coordinator** leases jobs to **worker nodes**
running on users' machines. Each worker is a **local AI execution gateway**: it can run a
local model (Ollama / llama.cpp / LM Studio / vLLM) or call a user-owned external provider
(OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, custom OpenAI-compatible).

## Core rule

**Provider tokens never leave the worker.** The coordinator only ever sees capabilities and
usage metadata, and routes jobs by capability / privacy / trust / cost / policy.

## Layout

```
worker/        Rust + Tauri worker node
  crates/
    worker-core/   adapters, token vault, usage, policy, coordinator client
    worker-cli/    clap CLI binary (headless nodes)
    worker-tauri/  Tauri desktop app (UI commands → worker-core)
  ui/              Tauri web frontend
coordinator/   Elixir / Phoenix coordinator (channels, routing, Oban leasing)
proto/         shared wire schemas (source of truth; serde + Ecto validate against these)
```

See `worker/README.md` and `coordinator/README.md` for build instructions.
