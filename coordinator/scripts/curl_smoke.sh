#!/usr/bin/env bash
#
# curl smoke test for the coordinator's :4000 endpoints.
#
# The coordinator exposes ONE HTTP surface: the worker WebSocket at /worker/websocket. Its
# auth gate (Coordinator.WorkerSocket.connect/3) runs during the WS upgrade handshake, so the
# HTTP status of the upgrade *is* the auth result:
#
#     101 Switching Protocols  -> accepted
#     403 Forbidden            -> rejected
#     400 Bad Request          -> not a WebSocket upgrade (plain GET)
#
# Expected results depend on coordinator config:
#   - open (no HYDRA_JOIN_TOKEN, HYDRA_REQUIRE_DEVICE_AUTH unset): bare upgrade -> 101
#   - HYDRA_REQUIRE_DEVICE_AUTH=true: bare upgrade -> 403, valid device key -> 101
#
# Usage: BASE=http://127.0.0.1:4000 ./curl_smoke.sh
set -u

BASE="${BASE:-http://127.0.0.1:4000}"
WS="$BASE/worker/websocket?vsn=2.0.0"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# urlencode the +, /, = that appear in base64.
b64url() { sed -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'; }

# HTTP status of a WS upgrade to $1 (extra query appended). Echoes the numeric code.
ws_status() {
  curl -s -o /dev/null -D - --max-time 4 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    "$1" 2>/dev/null | awk 'NR==1{print $2}'
}

# plain (non-upgrade) GET status of $1.
get_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then printf '  ok   %-38s %s\n' "$1" "$3"; pass=$((pass+1));
  else printf '  FAIL %-38s got %s, want %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

echo "coordinator @ $BASE"
echo

echo "[plain HTTP]"
check "GET /worker/websocket (no upgrade)" 400 "$(get_status "$WS")"

echo "[websocket upgrade — no auth]"
echo "  (101 if coordinator is open; 403 if HYDRA_REQUIRE_DEVICE_AUTH=true)"
ws_status "$WS" | { read -r c; printf '  ->   bare upgrade%*s%s\n' 26 '' "$c"; }

echo "[websocket upgrade — invalid device key]"
check "garbage pubkey/sig" 403 \
  "$(ws_status "$WS&worker_id=curl-bad&pubkey=AAAA&ts=$(date +%s)&nonce=AAAA&sig=AAAA")"

echo "[websocket upgrade — valid Ed25519 device key]"
WID="curl-test-$(date +%s)"
TS="$(date +%s)"
NONCE_RAW="$(openssl rand -base64 12 | tr -d '\n')"
openssl genpkey -algorithm ed25519 -out "$TMP/priv.pem" 2>/dev/null
# raw 32-byte public key = last 32 bytes of the DER SubjectPublicKeyInfo.
PUB_B64="$(openssl pkey -in "$TMP/priv.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)"
printf '%s' "$WID|$TS|$NONCE_RAW" > "$TMP/msg.txt"
openssl pkeyutl -sign -inkey "$TMP/priv.pem" -rawin -in "$TMP/msg.txt" -out "$TMP/sig.bin" 2>/dev/null
SIG_B64="$(base64 -w0 "$TMP/sig.bin")"
Q="worker_id=$WID&pubkey=$(printf '%s' "$PUB_B64" | b64url)&ts=$TS&nonce=$(printf '%s' "$NONCE_RAW" | b64url)&sig=$(printf '%s' "$SIG_B64" | b64url)"
check "signed challenge enrolls (TOFU)" 101 "$(ws_status "$WS&$Q")"
# Replay the SAME signed challenge a moment later -> same key, still accepted.
check "same key reconnects" 101 "$(ws_status "$WS&$Q")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
