#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building TypeScript..."
npm run build > /dev/null

# Load .env variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

PIDS=()

cleanup() {
  echo ""
  echo "🛑 Shutting down MCP Server..."
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# 1. Start vibervn-context-engine if not running
if ! curl -s http://127.0.0.1:6699/ > /dev/null; then
  echo "⚡ Starting vibervn-context-engine on port 6699..."
  ENGINE_DIR="/home/ubuntu/Documents/vibervn-context-engine"
  if [ -d "$ENGINE_DIR" ]; then
    (cd "$ENGINE_DIR" && export PATH="$HOME/.cargo/bin:$PATH" && cargo run -- --port 6699 > /tmp/context-engine.log 2>&1 &)
  fi
fi

# 2. Ensure Caddy container is running
if command -v docker &> /dev/null && [ -d "/home/ubuntu/mcp-stack" ]; then
  echo "🔒 Ensuring Caddy Reverse Proxy is active..."
  (cd /home/ubuntu/mcp-stack && docker compose up -d > /dev/null 2>&1)
fi

# 3. Start chatgpt-local-coder
echo "🚀 Starting chatgpt-local-coder on port 3000..."
node dist/index.js &
PIDS+=($!)

sleep 2

MCP_AUTH_PATH="${MCP_TOKEN:+/mcp/${MCP_TOKEN}}"
MCP_AUTH_PATH="${MCP_AUTH_PATH:-/mcp}"

echo ""
echo "=========================================================================="
echo "  ✅ MCP SERVER & CADDY PUBLIC ENDPOINTS READY!"
echo "=========================================================================="
echo ""
echo "  📌 CADDY HTTPS CONNECTOR URL (CHATGPT / CLAUDE / GEMINI):"
echo "  👉  https://mcp-140-245-49-68.sslip.io${MCP_AUTH_PATH}"
echo ""
echo "  ⚡ DIRECT CONTEXT ENGINE CADDY URL:"
echo "  👉  https://engine-140-245-49-68.sslip.io/mcp"
echo ""
echo "  🏠 LOCAL HEALTH CHECK:"
echo "  👉  http://127.0.0.1:3000/health"
echo ""
echo "=========================================================================="
echo "  (Press Ctrl+C to stop services)"
echo ""

wait "${PIDS[0]}"
