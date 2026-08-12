const port = process.env.MCP_WATCHDOG_PORT || process.env.PORT || "3002";
const token = (process.env.MCP_TOKEN || "").trim();
const mcpPath = token ? `/mcp/${encodeURIComponent(token)}` : "/mcp";
const baseUrl = `http://127.0.0.1:${port}${mcpPath}`;
const protocolVersion = "2025-03-26";

async function request(method, body, sessionId) {
  const headers = {
    Accept: "application/json, text/event-stream",
  };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (sessionId) {
    headers["mcp-session-id"] = sessionId;
    headers["mcp-protocol-version"] = protocolVersion;
  }

  const response = await fetch(baseUrl, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {}
  return { response, json };
}

let sessionId;
try {
  const init = await request("POST", {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion,
      capabilities: {},
      clientInfo: { name: "codex-mcp-watchdog", version: "1.0.0" },
    },
  });
  if (!init.response.ok) throw new Error(`initialize HTTP ${init.response.status}`);
  sessionId = init.response.headers.get("mcp-session-id");
  if (!sessionId) throw new Error("initialize missing mcp-session-id");

  const initialized = await request(
    "POST",
    { jsonrpc: "2.0", method: "notifications/initialized" },
    sessionId
  );
  if (!initialized.response.ok && initialized.response.status !== 202) {
    throw new Error(`initialized HTTP ${initialized.response.status}`);
  }

  const list = await request(
    "POST",
    { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
    sessionId
  );
  if (!list.response.ok) throw new Error(`tools/list HTTP ${list.response.status}`);
  const tools = list.json?.result?.tools;
  if (!Array.isArray(tools) || !tools.some((tool) => tool.name === "agent_status")) {
    throw new Error("tools/list missing agent_status");
  }

  const call = await request(
    "POST",
    {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "agent_status", arguments: {} },
    },
    sessionId
  );
  if (!call.response.ok || !call.json?.result) {
    throw new Error(`tools/call agent_status HTTP ${call.response.status}`);
  }

  console.log(`MCP readiness OK (${tools.length} tools)`);
} finally {
  if (sessionId) {
    try {
      await request("DELETE", undefined, sessionId);
    } catch {}
  }
}
