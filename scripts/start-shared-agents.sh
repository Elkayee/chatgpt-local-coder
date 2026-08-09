#!/usr/bin/env bash
# Launch shared agents with Headroom-backed shared memory context.
# Usage:
#   scripts/start-shared-agents.sh codex
#   scripts/start-shared-agents.sh claude
#   scripts/start-shared-agents.sh agy
#   scripts/start-shared-agents.sh status
#   scripts/start-shared-agents.sh repair-codex
#
# Design: Headroom proxy is run or reused at 127.0.0.1:8787.
# For Codex, we repair the configuration to use the proxy and run Codex directly
# instead of calling "headroom wrap codex" each time (which corrupts the TOML).

set -euo pipefail

AGENT="${1:-codex}"
shift || true

# Resolve python executable
PYTHON_BIN="python3"
if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "Error: Python runtime not found."
    exit 1
  fi
fi

# Verify headroom is installed
if ! "$PYTHON_BIN" -c "import headroom" >/dev/null 2>&1; then
  echo "Error: headroom-ai is not installed in the current Python environment."
  echo "Please install it using: pip install --user headroom-ai --break-system-packages"
  exit 1
fi

# Preflight: memory sync needs an embedder.
check_memory_embedder() {
  "$PYTHON_BIN" - <<'PY'
import importlib.util as u
onnx = u.find_spec("onnxruntime") and u.find_spec("tokenizers")
st = u.find_spec("sentence_transformers")
raise SystemExit(0 if (onnx or st) else 1)
PY
}
if ! check_memory_embedder; then
  echo "  Warning: memory sync has no usable embedder (need onnxruntime+tokenizers OR sentence-transformers)." >&2
  echo "           Fix: pip install --user 'headroom-ai[all]' --break-system-packages" >&2
  echo "           (memory will be degraded until this is installed)" >&2
fi

# Does `headroom wrap <sub>` exist in the installed version?
wrap_supports() {
  "$PYTHON_BIN" -m headroom.cli wrap "$1" --help >/dev/null 2>&1
}

# Preserve a custom Anthropic upstream
preserve_anthropic_upstream() {
  if [ -n "${ANTHROPIC_BASE_URL:-}" ] && [ -z "${ANTHROPIC_TARGET_API_URL:-}" ]; then
    export ANTHROPIC_TARGET_API_URL="$ANTHROPIC_BASE_URL"
  fi
}

existing_headroom_proxy_pid() {
  local pid=""

  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -tiTCP:"$HEADROOM_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  fi

  if [ -z "$pid" ] && command -v ss >/dev/null 2>&1; then
    pid="$(
      ss -ltnp 2>/dev/null \
        | awk -v port=":$HEADROOM_PORT" '
            index($4, port) && match($0, /pid=[0-9]+/) {
              print substr($0, RSTART + 4, RLENGTH - 4)
              exit
            }
          ' \
        || true
    )"
  fi

  if [ -z "$pid" ] && command -v pgrep >/dev/null 2>&1; then
    pid="$(pgrep -f "headroom\\.cli proxy.*--port[ =]$HEADROOM_PORT" | head -n 1 || true)"
  fi

  printf '%s' "$pid"
}

build_wrap_proxy_args() {
  WRAP_PROXY_ARGS=(--port "$HEADROOM_PORT")

  local pid
  pid="$(existing_headroom_proxy_pid)"
  if [ -n "$pid" ]; then
    echo "Reusing existing Headroom proxy on port $HEADROOM_PORT (PID $pid)."
    WRAP_PROXY_ARGS+=(--no-proxy)
  fi
}

ensure_headroom_proxy() {
  local pid
  pid="$(existing_headroom_proxy_pid)"
  if [ -n "$pid" ]; then
    echo "Reusing existing Headroom proxy on port $HEADROOM_PORT (PID $pid)."
  else
    echo "Starting Headroom proxy in background on port $HEADROOM_PORT..."
    mkdir -p "$HOME/.headroom/logs"
    nohup "$PYTHON_BIN" -m headroom.cli proxy --port "$HEADROOM_PORT" --memory --code-graph > "$HOME/.headroom/logs/proxy-stdout.log" 2>&1 &
    
    # Wait for proxy to start listening
    local count=0
    while [ $count -lt 30 ]; do
      if [ -n "$(existing_headroom_proxy_pid)" ]; then
        echo "Headroom proxy started successfully."
        return 0
      fi
      sleep 0.5
      count=$((count + 1))
    done
    echo "Warning: Headroom proxy did not start listening within 15 seconds." >&2
  fi
}

repair_codex_config() {
  echo "Repairing ~/.codex/config.toml..."
  "$PYTHON_BIN" - <<'EOF'
import os
import re
import tomllib
import datetime
import shutil
import sys

def quote_key(k):
    if not re.match(r"^[A-Za-z0-9_-]+$", k):
        escaped = k.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return k

def serialize_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    elif isinstance(v, (int, float)):
        return str(v)
    elif isinstance(v, str):
        return f'"{v}"'
    elif isinstance(v, list):
        items = ", ".join(serialize_val(x) for x in v)
        return f"[{items}]"
    elif isinstance(v, dict):
        items = ", ".join(f"{quote_key(k)} = {serialize_val(val)}" for k, val in sorted(v.items()))
        return f"{{ {items} }}"
    return str(v)

def serialize_toml(data):
    lines = []
    # Top-level variables
    for k, v in sorted(data.items()):
        if not isinstance(v, dict):
            lines.append(f"{quote_key(k)} = {serialize_val(v)}")
    
    # Tables
    def write_table(path, d):
        has_values = any(not isinstance(val, dict) for val in d.values())
        if has_values:
            lines.append(f"\n[{path}]")
            for k, v in sorted(d.items()):
                if not isinstance(v, dict):
                    lines.append(f"{quote_key(k)} = {serialize_val(v)}")
        
        for k, v in sorted(d.items()):
            if isinstance(v, dict):
                sub_path = f"{path}.{quote_key(k)}" if path else quote_key(k)
                write_table(sub_path, v)

    for k, v in sorted(data.items()):
        if isinstance(v, dict):
            write_table(quote_key(k), v)
            
    return "\n".join(lines) + "\n"

def pre_clean_toml(content):
    lines = content.splitlines()
    cleaned_lines = []
    current_section = ""
    seen_sections = set()
    seen_keys = {}
    
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            cleaned_lines.append(line)
            continue
            
        clean_line = stripped.split("#")[0].strip()
        
        if clean_line.startswith("[") and clean_line.endswith("]"):
            section_name = clean_line[1:-1].strip()
            if section_name in seen_sections:
                current_section = "__duplicate__"
                continue
            else:
                seen_sections.add(section_name)
                current_section = section_name
                seen_keys[section_name] = set()
                cleaned_lines.append(line)
                continue
                
        if "=" in clean_line and not clean_line.startswith("["):
            key = clean_line.split("=")[0].strip()
            if current_section == "__duplicate__":
                continue
                
            keys_in_section = seen_keys.setdefault(current_section, set())
            if key in keys_in_section:
                continue
            else:
                keys_in_section.add(key)
                cleaned_lines.append(line)
                continue
        
        if current_section != "__duplicate__":
            cleaned_lines.append(line)
            
    return "\n".join(cleaned_lines)

config_path = os.path.expanduser("~/.codex/config.toml")
if not os.path.exists(config_path):
    print(f"Error: {config_path} does not exist.")
    sys.exit(1)

# Backup config
timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
bak_path = f"{config_path}.bak.{timestamp}"
shutil.copy2(config_path, bak_path)
print(f"Backup created at: {bak_path}")

try:
    with open(config_path, "r", encoding="utf-8") as f:
        orig_content = f.read()
    
    # Pre-clean duplicates before parsing
    cleaned_content = pre_clean_toml(orig_content)
    data = tomllib.loads(cleaned_content)
    
    # Apply updates
    data["model_provider"] = "headroom"
    data["openai_base_url"] = "http://127.0.0.1:8787/v1"
    
    # Rebuild model_providers.headroom
    model_providers = data.setdefault("model_providers", {})
    model_providers["headroom"] = {
        "name": "OpenAI via Headroom proxy",
        "base_url": "http://127.0.0.1:8787/v1",
        "supports_websockets": True,
        "requires_openai_auth": True,
        "env_http_headers": { "X-Headroom-Project": "HEADROOM_PROJECT" }
    }
    
    # Rebuild mcp_servers.tokensave (preserving tools)
    mcp_servers = data.setdefault("mcp_servers", {})
    tokensave = mcp_servers.setdefault("tokensave", {})
    tools = tokensave.get("tools", {})
    tokensave.clear()
    tokensave.update({
        "command": "/home/tung/.local/bin/tokensave",
        "args": ["serve"],
        "enabled": True,
        "startup_timeout_sec": 30,
        "tool_timeout_sec": 120,
        "default_tools_approval_mode": "auto",
    })
    if tools:
        tokensave["tools"] = tools
        
    # Rebuild GitNexus Command
    gitnexus = mcp_servers.setdefault("gitnexus", {})
    gitnexus["command"] = "/home/tung/.nvm/versions/node/v24.14.0/bin/gitnexus"
    gitnexus["args"] = ["mcp"]
    
    # Rebuild Headroom Command
    headroom = mcp_servers.setdefault("headroom", {})
    headroom["command"] = "/home/tung/.local/bin/headroom"
    headroom["args"] = ["mcp", "serve"]
    
    # Rebuild Headroom Memory Command
    headroom_memory = mcp_servers.setdefault("headroom_memory", {})
    headroom_memory["command"] = "/usr/bin/python3"
    headroom_memory["args"] = ["-m", "headroom.memory.mcp_server", "--user", "tung"]
    headroom_memory["startup_timeout_sec"] = 30
    headroom_memory["tool_timeout_sec"] = 30
    
    # Serialize and save
    serialized = serialize_toml(data)
    
    # Validate output
    tomllib.loads(serialized)
    
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(serialized)
        
    print(f"Valid TOML: {config_path}")
    print("[shared-agents] Codex configuration parses successfully.")
except Exception as e:
    print(f"Failed to repair TOML configuration: {e}")
    sys.exit(1)
EOF
}

# Fallback accelerator environment variables
if [ "$(uname -s)" = "Darwin" ]; then
  export HEADROOM_EMBEDDER_RUNTIME="${HEADROOM_EMBEDDER_RUNTIME:-pytorch_mps}"
fi
export HEADROOM_PORT="${HEADROOM_PORT:-8787}"
export HEADROOM_WRAP_PROXY_TIMEOUT="${HEADROOM_WRAP_PROXY_TIMEOUT:-120}"

build_wrap_proxy_args

case "$AGENT" in
  repair-codex)
    repair_codex_config
    # Run codex --version to verify Codex can read the config
    if command -v codex >/dev/null 2>&1; then
      echo "Verifying Codex configuration with 'codex --version'..."
      codex --version
    fi
    ;;

  status)
    echo "Checking shared agents status..."
    pid="$(existing_headroom_proxy_pid)"
    if [ -n "$pid" ]; then
      echo "Headroom proxy: RUNNING (PID $pid, port $HEADROOM_PORT)"
    else
      echo "Headroom proxy: NOT RUNNING"
    fi
    
    config_path="$HOME/.codex/config.toml"
    if [ -f "$config_path" ]; then
      echo "Codex config: Found ($config_path)"
      if "$PYTHON_BIN" -c "import tomllib; tomllib.load(open('$config_path', 'rb'))" >/dev/null 2>&1; then
        echo "Codex config status: VALID TOML"
      else
        echo "Codex config status: INVALID TOML"
      fi
    else
      echo "Codex config: NOT FOUND"
    fi
    ;;

  codex)
    preserve_anthropic_upstream
    ensure_headroom_proxy
    repair_codex_config
    echo "Starting Codex directly through Headroom proxy..."
    exec codex "$@"
    ;;

  claude|claude-code)
    preserve_anthropic_upstream
    echo "Starting Claude Code wrapped with Headroom (Dangerous Skip; preserves custom Anthropic upstream if configured)..."
    exec "$PYTHON_BIN" -m headroom.cli wrap claude --memory --code-graph "${WRAP_PROXY_ARGS[@]}" -- --dangerously-skip-permissions "$@"
    ;;

  agy|antigravity|agy-cli)
    if wrap_supports agy; then
      preserve_anthropic_upstream
      echo "Starting Antigravity (agy) wrapped with Headroom (Memory)..."
      exec "$PYTHON_BIN" -m headroom.cli wrap agy --memory "${WRAP_PROXY_ARGS[@]}" -- --dangerously-skip-permissions "$@"
    fi
    agy_bin="$(command -v agy || true)"
    if [ -z "$agy_bin" ]; then
      echo "Error: 'agy' not found in PATH." >&2
      exit 1
    fi
    echo "Note: this Headroom ($("$PYTHON_BIN" -c 'import headroom;print(headroom.__version__)')) has no 'agy' wrap target;" >&2
    echo "      launching agy directly (Antigravity uses Google/Gemini, not the Anthropic proxy)." >&2
    exec "$agy_bin" --dangerously-skip-permissions "$@"
    ;;

  *)
    echo "Unknown agent/command: $AGENT"
    echo "Usage: scripts/start-shared-agents.sh [codex|claude|agy|status|repair-codex]"
    exit 1
    ;;
esac
