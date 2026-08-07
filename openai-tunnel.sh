#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TUNNEL_VERSION="v0.0.10"
BIN_DIR="$SCRIPT_DIR/bin"
TUNNEL_BIN="$BIN_DIR/tunnel-client"
PROFILE_DIR="$SCRIPT_DIR/profiles"
PROFILE_FILE="$PROFILE_DIR/codex-local.yaml"

get_dotenv_val() {
  local name="$1"
  if [ -f .env ]; then
    grep -E "^\s*${name}\s*=" .env | grep -v "^\s*#" | head -n1 | cut -d'=' -f2- | sed "s/^['\"]//;s/['\"]$//" | xargs
  fi
}

set_dotenv_val() {
  local name="$1"
  local val="$2"
  if [ ! -f .env ]; then
    cp .env.example .env
  fi
  if grep -q -E "^\s*${name}\s*=" .env; then
    sed -i "s|^\s*${name}\s*=.*|${name}=${val}|" .env
  else
    echo "${name}=${val}" >> .env
  fi
}

install_tunnel_client() {
  if [ -x "$TUNNEL_BIN" ]; then
    echo "tunnel-client is already installed at $TUNNEL_BIN"
    return 0
  fi
  echo "Downloading tunnel-client $TUNNEL_VERSION for Linux..."
  mkdir -p "$BIN_DIR"
  local zip_path="/tmp/tunnel-client.zip"
  curl -sSL "https://github.com/openai/tunnel-client/releases/download/$TUNNEL_VERSION/tunnel-client-$TUNNEL_VERSION-linux-amd64.zip" -o "$zip_path"
  unzip -o "$zip_path" -d "$BIN_DIR/"
  chmod +x "$TUNNEL_BIN"
  rm -f "$zip_path"
  echo "Installed: $TUNNEL_BIN"
}

ensure_profile() {
  local tunnel_id="$1"
  local port="${2:-3000}"
  local health_port="${3:-8080}"
  mkdir -p "$PROFILE_DIR"
  cat <<EOF > "$PROFILE_FILE"
config_version: 1
control_plane:
  tunnel_id: $tunnel_id
  api_key: env:OPENAI_TUNNEL_API_KEY
log:
  level: info
  format: struct-text
health:
  listen_addr: 127.0.0.1:$health_port
mcp:
  server_urls:
    - channel: main
      url: http://127.0.0.1:$port/mcp
EOF
}

if [ "$1" = "--init" ];  then
  echo "=== OpenAI Tunnel Setup ==="
  echo "You need 2 credentials from OpenAI Platform:"
  echo "  1. Tunnel ID:  https://platform.openai.com/settings/organization/tunnels"
  echo "  2. API Key:    https://platform.openai.com/settings/organization/api-keys (Runtime Key)"
  echo ""
  
  read -p "Enter OPENAI_TUNNEL_ID (tunnel_...): " input_id
  read -p "Enter OPENAI_TUNNEL_API_KEY (sk-...): " input_key
  
  if [ -n "$input_id" ]; then
    set_dotenv_val "OPENAI_TUNNEL_ID" "$input_id"
  fi
  if [ -n "$input_key" ]; then
    set_dotenv_val "OPENAI_TUNNEL_API_KEY" "$input_key"
  fi
fi

TUNNEL_ID=$(get_dotenv_val "OPENAI_TUNNEL_ID")
API_KEY=$(get_dotenv_val "OPENAI_TUNNEL_API_KEY")
PORT=$(get_dotenv_val "PORT")
PORT="${PORT:-3000}"
HEALTH_PORT=$(get_dotenv_val "OPENAI_TUNNEL_HEALTH_PORT")
HEALTH_PORT="${HEALTH_PORT:-8080}"

if [ -z "$TUNNEL_ID" ] || [ -z "$API_KEY" ]; then
  echo "[ERROR] Missing OPENAI_TUNNEL_ID or OPENAI_TUNNEL_API_KEY in .env"
  echo "Run: ./openai-tunnel.sh --init"
  echo "Or update .env directly with:"
  echo "  OPENAI_TUNNEL_ID=tunnel_..."
  echo "  OPENAI_TUNNEL_API_KEY=sk-..."
  exit 1
fi

install_tunnel_client
ensure_profile "$TUNNEL_ID" "$PORT" "$HEALTH_PORT"

export OPENAI_TUNNEL_API_KEY="$API_KEY"
export CONTROL_PLANE_API_KEY="$API_KEY"
export CONTROL_PLANE_TUNNEL_ID="$TUNNEL_ID"

if [ "$1" = "--doctor" ]; then
  "$TUNNEL_BIN" doctor --profile-file "$PROFILE_FILE" --explain
  exit $?
fi

echo "=== Starting OpenAI Secure MCP Tunnel ==="
echo "Tunnel ID: $TUNNEL_ID"
echo "Target MCP: http://127.0.0.1:$PORT/mcp"
echo ""

"$TUNNEL_BIN" run --profile-file "$PROFILE_FILE"
