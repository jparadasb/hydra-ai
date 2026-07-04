#!/usr/bin/env bash
# Smoke-test a hydra worker end-to-end through opencode.
#
#   opencode  --(OpenAI-compatible /v1)-->  coordinator  --(WS lease)-->  worker  --> provider
#
# It (1) makes sure a worker is connected to the local dev coordinator, (2) asks opencode
# to generate a small program using a worker-served model, and (3) runs that program to
# prove the response is real, working code — not just a 200.
#
# Prereqs: local coordinator up (docker compose up -d coordinator), opencode installed,
# and an opencode provider named `hydra-local` pointing at http://127.0.0.1:4000/v1.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COORD="${HYDRA_COORDINATOR_HTTP:-http://127.0.0.1:4000}"
WS="${HYDRA_COORDINATOR_URL:-ws://127.0.0.1:4000}"
MODEL="${HYDRA_TEST_MODEL:-gpt-5.4-mini}"           # must be a model the worker advertises
OC_MODEL="hydra-local/${MODEL}"
: "${HYDRA_VAULT_PASSPHRASE:?set HYDRA_VAULT_PASSPHRASE (this machine: the vault password)}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# 1. Ensure a worker is registered; if none, start the local CLI worker in the background.
if [ "$(curl -sf -m 5 "$COORD/v1/models" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo 0)" = "0" ]; then
  log "no models advertised — starting local worker"
  ( cd "$REPO/worker" && HYDRA_COORDINATOR_URL="$WS" \
      ./target/debug/hydra-worker run >/tmp/hydra-worker-test.log 2>&1 & )
  for _ in $(seq 1 15); do
    sleep 1
    [ "$(curl -sf -m 5 "$COORD/v1/models" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo 0)" != "0" ] && break
  done
fi
log "models advertised: $(curl -sf "$COORD/v1/models" | python3 -c 'import sys,json;print(", ".join(m["id"] for m in json.load(sys.stdin)["data"]))')"

# 2. Ask opencode (routed through the worker) to write a function.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log "opencode generating code via $OC_MODEL"
opencode run -m "$OC_MODEL" \
  'Write a Python function is_prime(n) returning True iff n is prime. Output ONLY a fenced python code block.' \
  2>/dev/null | tee "$WORK/out.txt"

# 3. Extract the code block and prove it runs.
python3 - "$WORK/out.txt" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"```(?:python)?\n(.*?)```", txt, re.S)
assert m, "no code block in worker response"
ns = {}
exec(m.group(1), ns)
got = [x for x in range(30) if ns["is_prime"](x)]
exp = [2,3,5,7,11,13,17,19,23,29]
assert got == exp, f"is_prime wrong: {got}"
print("\n\033[32mPASS\033[0m worker returned working code:", got)
PY
