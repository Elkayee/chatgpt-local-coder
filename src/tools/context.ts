import fs from "fs/promises";
import path from "path";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { validatePath } from "../lib/path-security.js";
import { audit, getAuditPath } from "../lib/audit.js";
import { describePermissionProfile, getPermissionProfile } from "../lib/permissions.js";
import { getDefaultCwd, getFullDiskAccess, getMachineRoots } from "../lib/path-security.js";
import { toolAnnotations } from "../lib/tool-annotations.js";
import { MCP_QUICKSTART } from "../lib/quickstart.js";
import { toolResult } from "../lib/tool-result.js";



const contextFileNames = [
  "CLAUDE.md",
  "AGENTS.md",
  "README.md",
  ".claude/settings.json",
  ".codex/config.toml",
  ".cursor/rules",
];

async function exists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function findContextFiles(root: string, maxDepth: number): Promise<string[]> {
  const found: string[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > maxDepth) return;

    for (const name of contextFileNames) {
      const candidate = path.join(dir, name);
      if (await exists(candidate)) found.push(candidate);
    }

    if (depth === maxDepth) return;

    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.name === "dist" || entry.name === "build") continue;
      await walk(path.join(dir, entry.name), depth + 1);
    }
  }

  await walk(root, 0);
  return [...new Set(found)];
}

export function registerContextTools(server: McpServer, workspaceRoot: string): void {
  server.registerTool(
    "project_context",
    {
      title: "Project Context",
      description:
        "Call after agent_status on first use. Loads AGENTS.md, CLAUDE.md, README.md and project config so you know how to work in this repo.",
      inputSchema: {
        path: z.string().optional().describe("Project directory, defaults to primary workspace"),
        max_depth: z.number().int().min(0).max(5).optional().default(3),
        max_bytes_per_file: z.number().int().positive().max(200000).optional().default(60000),
      },

      annotations: toolAnnotations("read"),
    },
    async ({ path: projectPath, max_depth, max_bytes_per_file }) => {
      const root = projectPath ? await validatePath(projectPath) : workspaceRoot;
      const files = await findContextFiles(root, max_depth);
      const fileContents: Array<{ path: string; content: string; truncated: boolean }> = [];

      for (const file of files) {
        try {
          const buf = await fs.readFile(file);
          const truncated = buf.length > max_bytes_per_file;
          const text = buf.subarray(0, max_bytes_per_file).toString("utf-8");
          fileContents.push({ path: file, content: text, truncated });
        } catch {}
      }

      await audit({ tool: "project_context", action: "read", target: root, status: "ok", details: { files: files.length } });
      return toolResult("project_context", { root, files: fileContents, count: fileContents.length });
    }
  );

  server.registerTool(
    "agent_status",
    {
      title: "Agent Status",
      description:
        "CALL THIS FIRST on every new ChatGPT session. Returns permissions, workspace roots, and a full MCP quickstart guide (tool cheat sheet + apply_patch format).",
      inputSchema: {},

      annotations: toolAnnotations("read"),
    },
    async () => {
      return toolResult("agent_status", {
        permission_profile: getPermissionProfile(),
        permission_description: describePermissionProfile(),
        full_machine_access: getFullDiskAccess(),
        default_cwd: getDefaultCwd(),
        machine_roots: getMachineRoots(),
        audit_log: getAuditPath(),
        pid: process.pid,
        node: process.version,
        quickstart: MCP_QUICKSTART,
      });
    }
  );
}