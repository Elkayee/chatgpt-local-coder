export const MCP_QUICKSTART = `
## First session workflow
1. Call agent_status (this tool) to confirm permissions and workspace roots.
2. Call project_context to load AGENTS.md / README / CLAUDE.md for the target project.
3. Explore with glob (file names) and grep (content), then read_text_file.
4. Edit with apply_patch (preferred), multi_edit, or write_file for new files.
5. Run builds/tests with run_command (short) or start_process + process_output (long).

## Output format
All tools return JSON: { ok, tool, summary, data }

## Tool cheat sheet
- glob / grep / read_text_file: explore (offset+limit for partial reads)
- apply_patch: single-file @@ hunks OR multi-file *** Begin Patch format
- create_directory / delete_directory / copy_file / move_file / delete_file
- run_command: persistent shell (cd persists); shell_status / shell_reset
- git_status / git_diff / git_add / git_commit / git_push / git_pull / git_stash

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

export function buildServerInstructions(workspaceRoot: string, workspaceRoots: string[], fullDiskAccess: boolean): string {
  const head = [
    "Local Codex coding MCP. FIRST call agent_status then project_context.",
    "Explore: glob, grep, read_text_file. Edit: apply_patch, multi_edit, write_file.",
    "Shell: run_command (persistent cwd). Git: git_status/git_add/git_commit/git_push.",
    `Default cwd: ${workspaceRoot}. Full machine access: ON (any absolute path).`,
  ].join(" ");

  const tail = [
    `Allowed roots:\n${workspaceRoots.map((r) => `- ${r}`).join("\n")}`,
    "Long commands: start_process + process_output. Paths: absolute or workspace-relative.",
    "See agent_status output for full quickstart guide.",
  ].join("\n");

  return `${head}\n\n${tail}`;
}