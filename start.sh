#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building TypeScript..."
npm run build > /dev/null

# Load .env variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

NGROK_BIN="./ngrok"
if [ ! -f "$NGROK_BIN" ]; then
  NGROK_BIN="ngrok"
fi

CLOUDFLARED_BIN="./cloudflared"
if [ ! -f "$CLOUDFLARED_BIN" ]; then
  CLOUDFLARED_BIN="cloudflared"
fi

TUNNEL_LOG="/tmp/tunnel_mcp.log"
OPENAI_LOG="/tmp/openai_mcp.log"
rm -f "$TUNNEL_LOG" "$OPENAI_LOG"

PIDS=()

cleanup() {
  echo ""
  echo "🛑 Shutting down MCP Server and all Tunnels..."
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -f "$TUNNEL_LOG" "$OPENAI_LOG"
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo "🚀 Starting MCP Server on port 3000..."
node dist/index.js &
PIDS+=($!)

# 1. Start Ngrok Tunnel (for Claude Web & Gemini Spark)
if [ -n "$NGROK_DOMAIN" ] && ([ -f "./ngrok" ] || command -v ngrok &> /dev/null); then
  echo "🌐 Starting Ngrok Tunnel (Claude Web & Gemini Spark)..."
  if [ -n "$NGROK_AUTHTOKEN" ]; then
    $NGROK_BIN config add-authtoken "$NGROK_AUTHTOKEN" > /dev/null 2>&1 || true
  fi
  $NGROK_BIN http 3000 --url="$NGROK_DOMAIN" > "$TUNNEL_LOG" 2>&1 &
  PIDS+=($!)
  NGROK_URL="https://${NGROK_DOMAIN}/mcp"
fi

# 2. Start OpenAI Secure MCP Tunnel (for ChatGPT Web)
if [ -n "$OPENAI_TUNNEL_ID" ] && [ -n "$OPENAI_TUNNEL_API_KEY" ] && [ -f "./openai-tunnel.sh" ]; then
  echo "🤖 Starting OpenAI Secure MCP Tunnel (ChatGPT Web)..."
  ./openai-tunnel.sh > "$OPENAI_LOG" 2>&1 &
  PIDS+=($!)
  OPENAI_STATUS="Connected (Tunnel ID: ${OPENAI_TUNNEL_ID})"
fi

sleep 2

echo ""
echo "=========================================================================="
echo "  ✅ MCP SERVER & TUNNELS SẴN SÀNG KHỞI CHẠY!"
echo "=========================================================================="
echo ""
if [ -n "$OPENAI_STATUS" ]; then
  echo "  🟢 CHATGPT DEVELOPER MODE TUNNEL:"
  echo "     Thư mục / Tunnel ID: ${OPENAI_TUNNEL_ID}"
  echo "     (ChatGPT tự động nhận diện qua Connector Settings)"
  echo ""
fi

if [ -n "$NGROK_URL" ]; then
  echo "  📌 CONNECTOR URL CỐ ĐỊNH (GEMINI SPARK & CLAUDE WEB):"
  echo "  👉  ${NGROK_URL}"
  echo ""
fi

echo "=========================================================================="
echo "  (Nhấn Ctrl+C để dừng tất cả dịch vụ)"
echo ""

wait "${PIDS[0]}"
