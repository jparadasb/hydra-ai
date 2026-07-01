#!/usr/bin/env bash
#
# Stress test for the coordinator's :4000 API.
#
# The coordinator exposes ONE HTTP surface: the worker WebSocket at /worker/websocket. Every
# connection runs the auth gate Coordinator.WorkerSocket.connect/3 during the upgrade
# handshake, and a device-key connect hits Postgres (TOFU lookup / enroll). So flooding the
# WS upgrade is a real end-to-end load test of the accept path: Cowboy -> Phoenix socket ->
# device-key Ed25519 verify -> DB.
#
# We measure the HTTP-upgrade response, not a full Phoenix channel session: the 101/403 status
# *is* the auth result, and time_starttransfer (TTFB) is the time to that status line — i.e.
# the auth-gate + DB latency. TTFB is the headline metric and is accurate even though curl
# lingers on the upgraded socket (a worker link is persistent by design).
#
# METHODOLOGY: a successful upgrade (101) is a persistent socket, so curl holds it until MAXT;
# wall-clock throughput is therefore bounded by CONCURRENCY/MAXT, not by the gate. To find the
# gate's real ceiling, RAMP CONCURRENCY and watch TTFB: flat TTFB = headroom, rising p95/p99 =
# the connect/3 + DB path saturating.
#
# Identities are pre-signed once (fixed ts) into a pool, so openssl key-gen/signing cost does
# not pollute the measured request loop. Pick POOL large to stress the enroll/insert path;
# pick it small to stress the steady-state verify/read path.
#
# Usage:
#   ./stress.sh                              # defaults: 2000 reqs, 50 concurrent, pool 50
#   REQUESTS=5000 CONCURRENCY=100 ./stress.sh
#   POOL=500 REQUESTS=500 ./stress.sh        # 500 unique workers -> 500 TOFU inserts
#   BASE=http://127.0.0.1:4000 ./stress.sh
#
# Env:
#   BASE         coordinator base URL            (default http://127.0.0.1:4000)
#   REQUESTS     total upgrade attempts          (default 2000)
#   CONCURRENCY  parallel in-flight requests     (default 50)
#   POOL         distinct pre-signed identities  (default 50, capped at REQUESTS)
#   TOKEN        HYDRA_JOIN_TOKEN, if the coordinator requires one (default empty)
#   MAXT         per-request curl --max-time sec (default 2; caps the persistent-socket linger)
#
# NOTE: the whole run must finish inside the device-auth freshness window (120s) because the
# signatures carry a fixed ts. Keep REQUESTS/CONCURRENCY sane for your box, or lower POOL.
set -u

BASE="${BASE:-http://127.0.0.1:4000}"
WS="$BASE/worker/websocket?vsn=2.0.0"
REQUESTS="${REQUESTS:-2000}"
CONCURRENCY="${CONCURRENCY:-50}"
POOL="${POOL:-50}"
TOKEN="${TOKEN:-}"
MAXT="${MAXT:-2}"
[ "$POOL" -gt "$REQUESTS" ] && POOL="$REQUESTS"

for bin in curl openssl awk xargs; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
POOLDIR="$TMP/pool"; mkdir -p "$POOLDIR"
RESULTS="$TMP/results"

# urlencode the +, /, = that appear in base64.
b64url() { sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'; }

echo "coordinator @ $BASE"
echo "requests=$REQUESTS  concurrency=$CONCURRENCY  pool=$POOL  token=$([ -n "$TOKEN" ] && echo set || echo none)"
echo

# --- 1. pre-sign a pool of valid Ed25519 device identities (fixed ts) -----------------------
echo "signing $POOL device identities..."
TS="$(date +%s)"
TOK_Q=""; [ -n "$TOKEN" ] && TOK_Q="&token=$(printf '%s' "$TOKEN" | b64url)"
for i in $(seq 0 $((POOL-1))); do
  WID="stress-$TS-$i"
  NONCE_RAW="$(openssl rand -base64 12 | tr -d '\n')"
  openssl genpkey -algorithm ed25519 -out "$TMP/k$i.pem" 2>/dev/null
  PUB_B64="$(openssl pkey -in "$TMP/k$i.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)"
  printf '%s' "$WID|$TS|$NONCE_RAW" > "$TMP/m$i.txt"
  openssl pkeyutl -sign -inkey "$TMP/k$i.pem" -rawin -in "$TMP/m$i.txt" -out "$TMP/s$i.bin" 2>/dev/null
  SIG_B64="$(base64 -w0 "$TMP/s$i.bin")"
  printf 'worker_id=%s&pubkey=%s&ts=%s&nonce=%s&sig=%s%s' \
    "$WID" "$(printf '%s' "$PUB_B64" | b64url)" "$TS" \
    "$(printf '%s' "$NONCE_RAW" | b64url)" "$(printf '%s' "$SIG_B64" | b64url)" "$TOK_Q" \
    > "$POOLDIR/$i.q"
done

# --- 2. one upgrade attempt; prints "<http_code> <ttfb_seconds>" --------------------------
req() {
  local q; q="$(cat "$POOLDIR/$(( $1 % POOL )).q")"
  curl -s -o /dev/null --max-time "$MAXT" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    -w '%{http_code} %{time_starttransfer}\n' \
    "$WS&$q" 2>/dev/null
  # curl's -w already emits "000 0.000000" on a real connection failure; no || fallback (that
  # double-counted, since an upgraded socket hits --max-time yet still reports its 101).
}
export -f req
export POOLDIR POOL WS MAXT

# --- 3. fire REQUESTS upgrades, CONCURRENCY in flight, time the wall clock -----------------
echo "firing $REQUESTS upgrades @ $CONCURRENCY concurrent..."
START="$(date +%s.%N)"
seq 0 $((REQUESTS-1)) | xargs -P "$CONCURRENCY" -I{} bash -c 'req {}' > "$RESULTS"
END="$(date +%s.%N)"

# --- 4. report -----------------------------------------------------------------------------
echo
awk -v start="$START" -v end="$END" -v reqs="$REQUESTS" '
{
  code[$1]++; n++;
  ms = $2 * 1000; lat[n] = ms; sum += ms;
  if (ms > max) max = ms;
}
END {
  wall = end - start; if (wall <= 0) wall = 0.000001;
  # sort latencies for percentiles
  asort(lat);
  printf "status codes:\n";
  for (c in code) {
    lbl = (c==101) ? "accepted" : (c==403) ? "rejected" : (c=="000") ? "conn fail" : "other";
    printf "  %-4s %6d  (%5.1f%%)  %s\n", c, code[c], 100.0*code[c]/n, lbl;
  }
  printf "\nthroughput (linger-bound — see METHODOLOGY; ramp CONCURRENCY):\n";
  printf "  wall time     %8.2f s\n", wall;
  printf "  completed/sec %8.1f\n", reqs/wall;
  printf "\nlatency (TTFB = auth-gate + DB, the real signal):\n";
  printf "  avg  %8.1f ms\n", sum/n;
  printf "  p50  %8.1f ms\n", p(50);
  printf "  p95  %8.1f ms\n", p(95);
  printf "  p99  %8.1f ms\n", p(99);
  printf "  max  %8.1f ms\n", max;
}
function p(q,   idx) { idx = int(q/100.0*n + 0.5); if (idx<1) idx=1; if (idx>n) idx=n; return lat[idx] }
' "$RESULTS"

echo
# success = 101 (open/valid) ; a coordinator requiring token/device-auth may legitimately 403
ok="$(awk '$1==101{c++} END{print c+0}' "$RESULTS")"
echo "accepted (101): $ok / $REQUESTS"
