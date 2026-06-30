#!/usr/bin/env bash
#
# Stress the coordinator's job-intake path (Coordinator.submit_job/1: Repo insert + Oban
# enqueue + Router decision). The coordinator has no HTTP job API, so this drives load straight
# into the LIVE release node with `bin/coordinator rpc`, which keeps a single Oban processing
# path (don't boot a second app instance against the same DB).
#
# It feeds scripts/stress_jobs.exs to rpc (defining StressJobs) and appends the run call with
# options interpolated from env (env vars can't cross into the rpc'd node, so they're baked in).
#
# Usage (from repo root or coordinator/):
#   ./stress_jobs.sh
#   TOTAL=5000 CONC=100 ./stress_jobs.sh
#   PRIVACY=local_only ALLOW_EXTERNAL=false ./stress_jobs.sh
#   WAIT_MS=3000 ./stress_jobs.sh          # also measure time-to-lease (needs a connected worker)
#
# Env:
#   TOTAL           total jobs to submit            (default 1000)
#   CONC            concurrent producer tasks       (default 50)
#   CAPABILITY      job capability                  (default chat)
#   PRIVACY         public|private|sensitive|local_only (default public)
#   ALLOW_EXTERNAL  true|false                      (default true)
#   WAIT_MS         poll each job this long for it to leave pending (default 0 = skip)
#   SERVICE         docker compose service name     (default coordinator)
#   BIN             release bin inside the container (default bin/coordinator)
#   COMPOSE         compose command                 (default: docker compose)
set -euo pipefail

TOTAL="${TOTAL:-1000}"
CONC="${CONC:-50}"
CAPABILITY="${CAPABILITY:-chat}"
PRIVACY="${PRIVACY:-public}"
ALLOW_EXTERNAL="${ALLOW_EXTERNAL:-true}"
WAIT_MS="${WAIT_MS:-0}"
SERVICE="${SERVICE:-coordinator}"
BIN="${BIN:-bin/coordinator}"
COMPOSE="${COMPOSE:-docker compose}"

# Resolve paths relative to this script so it runs from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXS="$HERE/stress_jobs.exs"
# docker-compose.yml lives at the repo root (one level above coordinator/).
ROOT="$(cd "$HERE/../.." && pwd)"

[ -f "$EXS" ] || { echo "missing $EXS" >&2; exit 2; }

CALL="StressJobs.run(total: $TOTAL, conc: $CONC, capability: \"$CAPABILITY\", privacy: \"$PRIVACY\", allow_external: $ALLOW_EXTERNAL, wait_ms: $WAIT_MS)"
EXPR="$(cat "$EXS")
$CALL"

echo "driving load into '$SERVICE' via $BIN rpc ..."
cd "$ROOT"
exec $COMPOSE exec -T "$SERVICE" "$BIN" rpc "$EXPR"
