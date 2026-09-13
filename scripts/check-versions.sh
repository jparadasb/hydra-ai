#!/usr/bin/env bash
# Assert the worker's three version declarations agree.
#
# They are three files because the desktop crate is excluded from the Cargo workspace (it links
# the webkit2gtk/gtk runtime) and so cannot inherit `[workspace.package] version`, and because
# Tauri reads its own JSON. Nothing checked them against each other, and
# `worker-app/Cargo.toml` sat at 0.1.0 through four releases as a result.
#
# Run from anywhere; CI runs it on every push.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

workspace="$repo_root/worker/Cargo.toml"
app_crate="$repo_root/worker/crates/worker-app/Cargo.toml"
tauri_conf="$repo_root/worker/crates/worker-app/tauri.conf.json"

# The first `version = "…"` under [workspace.package].
workspace_version="$(awk -F'"' '/^\[workspace.package\]/{f=1} f && /^version = /{print $2; exit}' "$workspace")"
app_version="$(awk -F'"' '/^\[package\]/{f=1} f && /^version = /{print $2; exit}' "$app_crate")"
tauri_version="$(awk -F'"' '/"version":/{print $4; exit}' "$tauri_conf")"

printf 'worker/Cargo.toml                     %s\n' "$workspace_version"
printf 'worker/crates/worker-app/Cargo.toml   %s\n' "$app_version"
printf 'worker/crates/worker-app/tauri.conf.json  %s\n' "$tauri_version"

if [ -z "$workspace_version" ] || [ -z "$app_version" ] || [ -z "$tauri_version" ]; then
  echo "error: could not read one of the versions — has a file's shape changed?" >&2
  exit 1
fi

if [ "$workspace_version" != "$app_version" ] || [ "$workspace_version" != "$tauri_version" ]; then
  cat >&2 <<EOF

error: worker version declarations disagree.

Set all three to the same value. A release stamps them from the tag, so a mismatch here means
a local build and a released build report different versions for the same commit.
EOF
  exit 1
fi

echo "OK — all three agree on $workspace_version"
