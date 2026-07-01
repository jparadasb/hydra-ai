#!/usr/bin/env bash
#
# Stress the OpenAI-compatible HTTP front-door (Coordinator.ApiRouter: POST /v1/chat/completions).
# Each request is a full round-trip — parse -> submit_job (Repo + Oban) -> wait on PubSub for the
# worker result -> map to OpenAI JSON -> respond — so unlike the WS-upgrade stress, these requests
# COMPLETE and throughput (requests/sec) is a real number.
#
# Outcomes depend on whether an eligible worker is connected:
#   - worker serving "chat" connected     -> 200 with a chat.completion (measures the full path)
#   - no worker                           -> 504 after TIMEOUT_MS (measures ingress + intake +
#                                            the blocking-wait/backpressure path)
# Either way it loads the new HTTP surface; for a no-worker run keep TIMEOUT_MS short.
#
# Usage:
#   ./stress_openai.sh
#   REQUESTS=2000 CONCURRENCY=100 ./stress_openai.sh
#   TIMEOUT_MS=1500 ./stress_openai.sh           # short server-side wait (no worker)
#   TOKEN=secret-key ./stress_openai.sh          # if HYDRA_API_TOKEN is set on the coordinator
#
# Env:
#   BASE         coordinator base URL            (default http://127.0.0.1:4000)
#   REQUESTS     total requests                  (default 1000)
#   CONCURRENCY  parallel in-flight requests     (default 50)
#   TIMEOUT_MS   per-request server wait (x-hydra-timeout-ms) (default 2000)
#   TOKEN        gateway bearer token            (default empty = open door)
#   MAXT         curl --max-time sec             (default: TIMEOUT_MS/1000 + 5)
set -u

BASE="${BASE:-http://127.0.0.1:4000}"
URL="$BASE/v1/chat/completions"
REQUESTS="${REQUESTS:-1000}"
CONCURRENCY="${CONCURRENCY:-50}"
TIMEOUT_MS="${TIMEOUT_MS:-2000}"
TOKEN="${TOKEN:-}"
MAXT="${MAXT:-$(( TIMEOUT_MS / 1000 + 5 ))}"

command -v curl >/dev/null || { echo "missing curl" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results"

AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "authorization: Bearer $TOKEN")

echo "front-door @ $URL"
echo "requests=$REQUESTS  concurrency=$CONCURRENCY  server-timeout=${TIMEOUT_MS}ms  token=$([ -n "$TOKEN" ] && echo set || echo none)"
echo

# One chat completion; prints "<http_code> <total_seconds>".
req() {
  local body
  body="{\"model\":\"hydra\",\"messages\":[{\"role\":\"user\",\"content\":\"stress $1\"}],\"max_tokens\":16,\"timeout_ms\":$TIMEOUT_MS}"
  curl -s -o /dev/null --max-time "$MAXT" \
    -H 'content-type: application/json' -H "x-hydra-timeout-ms: $TIMEOUT_MS" "${AUTH[@]}" \
    -d "$body" -w '%{http_code} %{time_total}\n' "$URL" 2>/dev/null
}
export -f req
export URL MAXT TIMEOUT_MS
export AUTH_HDR="${AUTH[*]:-}"

echo "firing $REQUESTS requests @ $CONCURRENCY concurrent..."
START="$(date +%s.%N)"
seq 0 $((REQUESTS-1)) | xargs -P "$CONCURRENCY" -I{} bash -c 'req {}' > "$RESULTS"
END="$(date +%s.%N)"

echo
awk -v start="$START" -v end="$END" -v reqs="$REQUESTS" '
{ code[$1]++; n++; ms=$2*1000; lat[n]=ms; sum+=ms; if (ms>max) max=ms }
END {
  wall = end - start; if (wall <= 0) wall = 0.000001;
  asort(lat);
  printf "status codes:\n";
  for (c in code) {
    lbl = (c=="200") ? "completed" : (c=="504") ? "no-worker timeout" : (c=="401") ? "unauthorized" \
        : (c=="400"||c=="422") ? "bad request" : (c=="000") ? "conn fail" : "other";
    printf "  %-4s %6d  (%5.1f%%)  %s\n", c, code[c], 100.0*code[c]/n, lbl;
  }
  printf "\nthroughput:\n";
  printf "  wall time     %8.2f s\n", wall;
  printf "  requests/sec  %8.1f\n", reqs/wall;
  printf "\nlatency (full request round-trip):\n";
  printf "  avg  %8.1f ms\n", sum/n;
  printf "  p50  %8.1f ms\n", p(50);
  printf "  p95  %8.1f ms\n", p(95);
  printf "  p99  %8.1f ms\n", p(99);
  printf "  max  %8.1f ms\n", max;
}
function p(q,   idx) { idx=int(q/100.0*n + 0.5); if (idx<1) idx=1; if (idx>n) idx=n; return lat[idx] }
' "$RESULTS"

echo
echo "completed (200): $(awk '$1=="200"{c++} END{print c+0}' "$RESULTS") / $REQUESTS"
