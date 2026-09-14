#!/usr/bin/env bash
set -euo pipefail

# Install Hydra MCP server in Codex. Usage:
#   curl -fsSL https://hydra.lambdatauri.dev/install-mcp.sh | bash
#   curl -fsSL https://hydra.lambdatauri.dev/install-mcp.sh | bash -s -- https://coordinator.example.com

BASE_URL="${1:-${HYDRA_URL:-https://hydra.lambdatauri.dev}}"
BASE_URL="${BASE_URL%/}"
MCP_URL="$BASE_URL/mcp"
CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CONFIG_DIR/config.toml"
START_MARKER="# hydra-ai MCP server (managed by install-mcp.sh)"
END_MARKER="# end hydra-ai MCP server"

printf 'Hydra gateway token: '
IFS= read -r -s TOKEN
printf '\n'
if [[ -z "$TOKEN" ]]; then
  echo "Token cannot be empty." >&2
  exit 1
fi

# Escape TOML string characters before writing the header value.
TOKEN_ESC="${TOKEN//\\/\\\\}"
TOKEN_ESC="${TOKEN_ESC//\"/\\\"}"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/hydra-mcp.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

awk -v start="$START_MARKER" -v end="$END_MARKER" '
  $0 == start { skip=1; next }
  $0 == end { skip=0; next }
  !skip { print }
' "$CONFIG_FILE" > "$TMP_FILE"

{
  sed '/^[[:space:]]*$/d' "$TMP_FILE"
  printf '\n%s\n[mcp_servers.hydra]\nurl = "%s"\nhttp_headers = { Authorization = "Bearer %s" }\n%s\n' \
    "$START_MARKER" "$MCP_URL" "$TOKEN_ESC" "$END_MARKER"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

unset TOKEN
echo "Hydra MCP installed in $CONFIG_FILE"
echo "Restart Codex to connect to $MCP_URL."
