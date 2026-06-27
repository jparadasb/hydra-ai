# worker/ui — desktop frontend

Web frontend for the Tauri worker app. Every action calls a `#[tauri::command]` that wraps
`worker-tauri::commands::Commands`. The frontend only ever receives DTOs from
`worker-tauri::dto` — **masked fingerprints, never raw tokens.**

## Screens

1. **Mode chooser (first run)** — local model / provider / both → writes worker config.
2. **Providers** — add / test / select-models / rotate / remove; shows masked fingerprint
   (`sk-...abcd`) and spending limits. Calls `add_provider`, `test_provider`,
   `rotate_provider`, `remove_provider`, `list_providers`.
3. **Privacy** — accepted job levels, allow private/sensitive toggles, routing preference.
4. **Usage** — per-provider/model table (requests, tokens, est. cost, success/fail, latency,
   daily/monthly). Calls `usage`.

## Token input contract

The token input box collects the raw token and passes it directly to the `add_provider`
command. The frontend must not persist it, log it, or render it back — the command returns a
fingerprint, which is the only form shown thereafter.

## Status

Scaffold/spec only. The command layer (`worker-tauri`) is implemented and tested; this
directory holds the Tauri runtime + HTML/JS shell to be built on top.
