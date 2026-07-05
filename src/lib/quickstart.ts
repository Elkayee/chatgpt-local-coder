export const MCP_QUICKSTART = `
## First session workflow
1. Call agent_status (this tool) to confirm permissions and workspace roots.
2. Call project_context to load AGENTS.md / README / CLAUDE.md for the target project.
3. Explore with glob (file names) and grep (content), then read_text_file.
4. Edit with apply_patch (preferred), multi_edit, or write_file for new files.
5. Run builds/tests with run_command (short) or start_process + process_output (long).
6. Undo file edits with rewind (list → preview → restore). Shell/bash file changes are not tracked.

## Output format
All tools return JSON: { ok, tool, summary, data }

## Tool cheat sheet
- glob / grep / read_text_file: explore (offset+limit for partial reads)
- apply_patch: single-file @@ hunks OR multi-file *** Begin Patch format
- create_directory / delete_directory / copy_file / move_file / delete_file
- run_command: persistent shell (cd persists); shell_status / shell_reset
- git_status / git_diff / git_add / git_commit / git_branch / git_restore / git_stash
- rewind: action=list|preview|restore|status — undo file edits via automatic checkpoints
- mcp_servers / mcp_tools / mcp_call — delegate to upstream MCP servers on this machine
- git_push / git_checkout / delete_directory: may be blocked by ChatGPT safety — use run_command fallback

## apply_patch — single file
@@
-old line
+new line
 context unchanged

## apply_patch — multi file
*** Begin Patch
*** Update File: src/foo.ts
@@
-old
+new
*** End Patch

## Paths
Full machine access — use ANY absolute path (C:\\, D:\\, etc.). Relative paths resolve from default cwd.
`.trim();

export function buildServerInstructions(
  workspaceRoot: string,
  workspaceRoots: string[],
  _fullDiskAccess: boolean,
  projectMemory?: string
): string {
  const head = [
    "Local Codex coding MCP (Claude Code-style). Default project cwd is WORKSPACE_PATH.",
    "Project memory below is auto-loaded from CLAUDE.md/AGENTS.md — treat it as ground truth.",
    "If the user names a different project path, call project_context(path) then work under that path.",
    "Explore: glob, grep, read_text_file. Edit: apply_patch, multi_edit, write_file.",
    "Shell: run_command (persistent cwd). Rewind: rewind action=list|restore.",
    `Default cwd: ${workspaceRoot}. Full machine access: ON (any absolute path).`,
  ].join(" ");

  const tail = [
    `Workspace roots:\n${workspaceRoots.map((r) => `- ${r}`).join("\n")}`,
    "Long commands: start_process + process_output. Paths: absolute or workspace-relative.",
    "Call agent_status for tool cheat sheet; project_context for another repo.",
  ].join("\n");

  const memory = projectMemory?.trim();
  if (!memory) return `${head}\n\n${tail}`;
  return `${head}\n\n${memory}\n\n${tail}`;
}