export type ToolProfileName = "full" | "slim";

/** Core tools for ChatGPT web — smaller tools/list payload, fewer discovery errors. */
export const SLIM_CHATGPT_TOOLS = new Set([
  "read_text_file",
  "write_file",
  "apply_patch",
  "glob",
  "grep",
  "run_command",
  "start_process",
  "process_output",
  "stop_process",
  "git_status",
  "git_diff",
  "git_commit",
  "agent_status",
  "project_context",
  "load_path_rules",
  "rewind",
  "mcp_servers",
  "codebase_retrieval__codebase-retrieval",
  "codebase-memory-mcp__trace_path",
  "codebase-memory-mcp__get_architecture",
  "tokensave__tokensave_affected",
  "tokensave__tokensave_record_decision",
  "tokensave__tokensave_record_code_area",
  "tokensave__tokensave_session_recall",
  "gitnexus__impact",
  "gitnexus__detect_changes",
]);

export function getChatGptToolProfile(): ToolProfileName {
  const raw = (process.env.CHATGPT_TOOL_PROFILE || "slim").trim().toLowerCase();
  return raw === "full" ? "full" : "slim";
}

export function shouldExposeTool(name: string, profile: ToolProfileName = getChatGptToolProfile()): boolean {
  if (profile === "full") return true;
  return SLIM_CHATGPT_TOOLS.has(name);
}
