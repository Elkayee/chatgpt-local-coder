import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerFilesystemTools } from "./tools/filesystem.js";
import { registerShellTools } from "./tools/shell.js";
import { registerGitTools } from "./tools/git.js";
import { registerContextTools } from "./tools/context.js";
import { buildServerInstructions } from "./lib/quickstart.js";

export function createMcpServer(
  workspaceRoot: string,
  shellTimeout: number,
  workspaceRoots: string[] = [workspaceRoot],
  fullDiskAccess = false
): McpServer {
  const server = new McpServer(
    {
      name: "codex-mcp-server",
      version: "2.0.0",
    },
    {
      capabilities: {
        logging: {},
        tools: { listChanged: true },
      },
      instructions: buildServerInstructions(workspaceRoot, workspaceRoots, fullDiskAccess),
    }
  );

  registerFilesystemTools(server);
  registerShellTools(server, workspaceRoot, shellTimeout);
  registerGitTools(server, workspaceRoot);
  registerContextTools(server, workspaceRoot);

  return server;
}