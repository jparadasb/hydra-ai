#!/usr/bin/env bash
# Configure a CLI coding agent to use the Hydra coordinator's OpenAI-compatible API.
#
# Targets:
#   opencode  (default) — merges a "hydra" provider into ~/.config/opencode/opencode.json
#   env                 — prints OPENAI_BASE_URL / OPENAI_API_KEY exports for any
#                         OpenAI-compatible CLI (aider, llm, codex, curl, ...)
#
# Usage:
#   scripts/setup-opencode.sh [--url https://hydra.lambdatauri.dev] [--key hydra_sk_...]
#                             [--target opencode|env] [--model MODEL_ID] [--embed-key]
#                             [--no-autosync]
#   scripts/setup-opencode.sh sync
#
# The gateway key is minted in the coordinator admin console (/admin -> API keys).
# By default the key is NOT written into the opencode config; the config references
# {env:HYDRA_API_KEY}, an export line is appended to your shell rc, and a 0600 copy is
# kept at ~/.config/opencode/.hydra_key for the sync timer. Use --embed-key to store it
# in the config file instead.
#
# Model auto-sync: setup installs a systemd user timer (cron fallback) that runs
# `setup-opencode.sh sync` every 15 minutes, refreshing provider.hydra.models from the
# coordinator's live /v1/models (workers come and go, so does the model list).
# Opt out with --no-autosync. `sync` can also be run by hand.
set -euo pipefail

URL="https://hydra.lambdatauri.dev"
KEY="${HYDRA_API_KEY:-}"
TARGET="opencode"
MODEL=""
EMBED_KEY=false
AUTOSYNC=true
DO_SYNC=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    sync)          DO_SYNC=true; shift ;;
    --url)         URL="$2"; shift 2 ;;
    --key)         KEY="$2"; shift 2 ;;
    --target)      TARGET="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --embed-key)   EMBED_KEY=true; shift ;;
    --no-autosync) AUTOSYNC=false; shift ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
CONFIG="$CONFIG_DIR/opencode.json"
KEY_FILE="$CONFIG_DIR/.hydra_key"

# --- sync: refresh provider.hydra.models from the live /v1/models --------------------
if $DO_SYNC; then
  [[ -f "$CONFIG" ]] || { echo "sync: $CONFIG not found — run setup first" >&2; exit 1; }
  SYNC_KEY="${HYDRA_API_KEY:-}"
  [[ -z "$SYNC_KEY" && -f "$KEY_FILE" ]] && SYNC_KEY=$(< "$KEY_FILE")
  CONFIG="$CONFIG" SYNC_KEY="$SYNC_KEY" python3 - <<'PY'
import json, os, sys, urllib.request

path = os.environ["CONFIG"]
with open(path) as f:
    cfg = json.load(f)

hydra = cfg.get("provider", {}).get("hydra")
if not hydra:
    sys.exit("sync: no hydra provider in config — run setup first")

base = hydra["options"]["baseURL"].rstrip("/")
key = os.environ.get("SYNC_KEY") or ""
api_key = hydra["options"].get("apiKey", "")
if not key and not api_key.startswith("{env:"):
    key = api_key  # --embed-key mode

req = urllib.request.Request(base + "/models", headers={"Authorization": "Bearer " + key})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        ids = sorted(m["id"] for m in json.load(r).get("data", []))
except Exception as e:
    print(f"sync: {base}/models unreachable ({e}) — keeping current list")
    sys.exit(0)

if not ids:
    print("sync: coordinator reports no models — keeping current list")
    sys.exit(0)

old = sorted(hydra.get("models", {}))
if ids == old:
    print(f"sync: up to date ({len(ids)} models)")
    sys.exit(0)

hydra["models"] = {mid: {"name": mid} for mid in ids}
# keep the default model valid
default = cfg.get("model", "")
if default.startswith("hydra/") and default[len("hydra/"):] not in ids:
    cfg["model"] = "hydra/" + ids[0]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"sync: models updated {old} -> {ids}")
PY
  exit $?
fi

URL="${URL%/}"
BASE_URL="$URL/v1"

if [[ -z "$KEY" ]]; then
  read -rsp "Hydra gateway key (hydra_sk_...): " KEY; echo
fi
[[ -n "$KEY" ]] || { echo "error: no API key provided" >&2; exit 1; }

# --- probe the coordinator (non-fatal: it may be offline right now) -----------------
MODELS_JSON=""
if curl -fsS -m 8 "$URL/health" >/dev/null 2>&1; then
  MODELS_JSON=$(curl -fsS -m 8 -H "Authorization: Bearer $KEY" "$BASE_URL/models" 2>/dev/null || true)
  echo "coordinator reachable at $URL"
else
  echo "warning: $URL/health not reachable — writing config anyway" >&2
fi

# Model ids advertised by connected workers; fallback to --model or a sane default.
mapfile -t MODEL_IDS < <(printf '%s' "$MODELS_JSON" \
  | python3 -c 'import json,sys
try:
    for m in json.load(sys.stdin).get("data", []): print(m["id"])
except Exception: pass' 2>/dev/null)
if [[ ${#MODEL_IDS[@]} -eq 0 ]]; then
  MODEL_IDS=("${MODEL:-Qwen3.6-35B-A3B}")
fi

case "$TARGET" in
env)
  echo
  echo "# add to your shell rc / CI env:"
  echo "export OPENAI_BASE_URL=\"$BASE_URL\""
  echo "export OPENAI_API_KEY=\"$KEY\""
  echo "export HYDRA_API_KEY=\"$KEY\""
  echo
  echo "# example: aider --openai-api-base \$OPENAI_BASE_URL --model openai/${MODEL_IDS[0]}"
  ;;

opencode)
  mkdir -p "$CONFIG_DIR"
  [[ -f "$CONFIG" ]] && cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

  if $EMBED_KEY; then API_KEY_VALUE="$KEY"; else API_KEY_VALUE="{env:HYDRA_API_KEY}"; fi

  CONFIG="$CONFIG" BASE_URL="$BASE_URL" API_KEY_VALUE="$API_KEY_VALUE" \
  DEFAULT_MODEL="${MODEL:-${MODEL_IDS[0]}}" MODEL_IDS="$(printf '%s\n' "${MODEL_IDS[@]}")" \
  python3 - <<'PY'
import json, os

path = os.environ["CONFIG"]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except json.JSONDecodeError: cfg = {}

models = {mid: {"name": mid} for mid in os.environ["MODEL_IDS"].splitlines() if mid}
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("provider", {})["hydra"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Hydra",
    "options": {
        "baseURL": os.environ["BASE_URL"],
        "apiKey": os.environ["API_KEY_VALUE"],
        # Slow local backends (M40) can take >60s for one completion; without this the
        # gateway 504s ("no worker completed the job in time") while the worker finishes.
        "headers": {"x-hydra-timeout-ms": "300000"},
    },
    "models": models,
}
cfg["model"] = "hydra/" + os.environ["DEFAULT_MODEL"]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"wrote {path}")
PY

  if ! $EMBED_KEY; then
    RC="${ZDOTDIR:-$HOME}/.zshrc"; [[ -f "$RC" ]] || RC="$HOME/.bashrc"
    if ! grep -q "HYDRA_API_KEY" "$RC" 2>/dev/null; then
      printf '\nexport HYDRA_API_KEY="%s"\n' "$KEY" >> "$RC"
      echo "appended HYDRA_API_KEY export to $RC (open a new shell or: source $RC)"
    else
      echo "HYDRA_API_KEY already referenced in $RC — left untouched"
    fi
  fi

  # key copy for the sync timer (cron/systemd don't see shell rc exports)
  (umask 077; printf '%s' "$KEY" > "$KEY_FILE")

  if $AUTOSYNC; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if systemctl --user is-system-running &> /dev/null; then
      mkdir -p "$HOME/.config/systemd/user"
      cat > "$HOME/.config/systemd/user/hydra-model-sync.service" <<EOF
[Unit]
Description=Refresh Hydra model list in opencode config

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH sync
EOF
      cat > "$HOME/.config/systemd/user/hydra-model-sync.timer" <<EOF
[Unit]
Description=Refresh Hydra model list every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable --now hydra-model-sync.timer
      echo "autosync: systemd user timer 'hydra-model-sync.timer' every 15min"
    elif command -v crontab > /dev/null; then
      CRON_LINE="*/15 * * * * $SCRIPT_PATH sync >/dev/null 2>&1"
      (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH sync"; echo "$CRON_LINE") | crontab -
      echo "autosync: cron entry every 15min"
    else
      echo "autosync: no systemd user session or crontab — run '$0 sync' manually" >&2
    fi
  fi

  echo
  echo "done. models configured: ${MODEL_IDS[*]}"
  echo "try:  opencode run -m hydra/${MODEL:-${MODEL_IDS[0]}} 'hello'"
  ;;

*)
  echo "error: unknown target '$TARGET' (opencode|env)" >&2; exit 1 ;;
esac
