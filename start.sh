#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building TypeScript..."
npm run build > /dev/null

# Load .env variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

TUNNEL_TYPE="cloudflared"
if [ -n "$NGROK_DOMAIN" ] && ([ -f "./ngrok" ] || command -v ngrok &> /dev/null); then
  TUNNEL_TYPE="ngrok"
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
rm -f "$TUNNEL_LOG"

cleanup() {
  echo ""
  echo "🛑 Shutting down MCP Server & Tunnel..."
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$TUNNEL_LOG"
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo "🚀 Starting MCP Server on port 3000..."
node dist/index.js &
SERVER_PID=$!

if [ "$TUNNEL_TYPE" = "ngrok" ]; then
  echo "🌐 Starting Ngrok Static Tunnel ($NGROK_DOMAIN)..."
  if [ -n "$NGROK_AUTHTOKEN" ]; then
    $NGROK_BIN config add-authtoken "$NGROK_AUTHTOKEN" > /dev/null 2>&1 || true
  fi
  $NGROK_BIN http 3000 --url="$NGROK_DOMAIN" > "$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  TUNNEL_URL="https://${NGROK_DOMAIN}"
else
  echo "🌐 Starting Cloudflare Quick Tunnel..."
  $CLOUDFLARED_BIN tunnel --url http://localhost:3000 > "$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!

  echo "⏳ Waiting for public tunnel URL..."
  TUNNEL_URL=""
  for i in {1..30}; do
    if grep -o "https://[a-zA-Z0-9-]*\.trycloudflare\.com" "$TUNNEL_LOG" > /tmp/cf_url.txt 2>/dev/null; then
      TUNNEL_URL=$(cat /tmp/cf_url.txt | head -n 1)
      if [ -n "$TUNNEL_URL" ]; then
        break
      fi
    fi
    sleep 0.5
  done
  rm -f /tmp/cf_url.txt
fi

sleep 1

echo ""
echo "=========================================================================="
echo "  ✅ MCP SERVER & TUNNEL SẴN SÀNG!"
echo "=========================================================================="
echo ""
if [ -n "$TUNNEL_URL" ]; then
  echo "  📌 LINK CONNECTOR CỐ ĐỊNH VĨNH VIỄN (GEMINI / CLAUDE WEB / CHATGPT):"
  echo ""
  echo "  👉  ${TUNNEL_URL}/mcp"
  echo ""
  echo "  (Sao chép link cố định trên và dán 1 LẦN DUY NHẤT vào Connector!)"
else
  echo "  ⚠️ Chưa lấy được URL Tunnel. Xem chi tiết log tại: $TUNNEL_LOG"
fi
echo "=========================================================================="
echo "  (Nhấn Ctrl+C để dừng cả Server và Tunnel)"
echo ""

wait $SERVER_PID
