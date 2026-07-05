import fs from "fs/promises";
import path from "path";

/** Mirrors Claude Code startup memory: CLAUDE.md + AGENTS.md at project root. */
const ROOT_MEMORY_FILES = [
  "CLAUDE.md",
  ".claude/CLAUDE.md",
  "AGENTS.md",
  "CLAUDE.local.md",
] as const;

const RULES_GLOB_MAX = 12;
const DEFAULT_MAX_BYTES = parseInt(process.env.PROJECT_MEMORY_MAX_BYTES || "25000", 10);
const DEFAULT_MAX_LINES = parseInt(process.env.PROJECT_MEMORY_MAX_LINES || "200", 10);

export interface ProjectMemorySection {
  path: string;
  content: string;
  truncated: boolean;
}

export interface ProjectMemoryBundle {
  root: string;
  sections: ProjectMemorySection[];
  total_bytes: number;
  loaded_at: string;
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readTextLimited(
  filePath: string,
  maxBytes: number,
  maxLines: number
): Promise<ProjectMemorySection | null> {
  try {
    const buf = await fs.readFile(filePath);
    const full = buf.toString("utf-8");
    const lines = full.split(/\r?\n/).slice(0, maxLines);
    const lineLimited = lines.join("\n");
    const byteLimited = Buffer.byteLength(lineLimited, "utf-8") > maxBytes
      ? lineLimited.slice(0, maxBytes)
      : lineLimited;
    const truncated =
      buf.length > maxBytes || full.split(/\r?\n/).length > maxLines || byteLimited.length < full.length;
    return { path: filePath, content: byteLimited.trim(), truncated };
  } catch {
    return null;
  }
}

async function listRuleFiles(rulesDir: string): Promise<string[]> {
  const found: string[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > 3) return;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full, depth + 1);
      } else if (entry.isFile() && entry.name.endsWith(".md")) {
        found.push(full);
      }
    }
  }

  await walk(rulesDir, 0);
  return found.sort().slice(0, RULES_GLOB_MAX);
}

/**
 * Load project memory like Claude Code does at session start:
 * root CLAUDE.md / AGENTS.md + optional .claude/rules/*.md
 */
export async function loadProjectMemory(
  workspaceRoot: string,
  opts?: { maxBytes?: number; maxLines?: number }
): Promise<ProjectMemoryBundle> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  const maxLines = opts?.maxLines ?? DEFAULT_MAX_LINES;
  const root = path.resolve(workspaceRoot);
  const sections: ProjectMemorySection[] = [];
  let totalBytes = 0;

  for (const rel of ROOT_MEMORY_FILES) {
    if (totalBytes >= maxBytes) break;
    const filePath = path.join(root, rel);
    if (!(await fileExists(filePath))) continue;
    const section = await readTextLimited(filePath, maxBytes - totalBytes, maxLines);
    if (!section?.content) continue;
    sections.push(section);
    totalBytes += Buffer.byteLength(section.content, "utf-8");
  }

  const rulesDir = path.join(root, ".claude", "rules");
  if (totalBytes < maxBytes && (await fileExists(rulesDir))) {
    for (const ruleFile of await listRuleFiles(rulesDir)) {
      if (totalBytes >= maxBytes) break;
      const section = await readTextLimited(ruleFile, maxBytes - totalBytes, maxLines);
      if (!section?.content) continue;
      sections.push(section);
      totalBytes += Buffer.byteLength(section.content, "utf-8");
    }
  }

  return {
    root,
    sections,
    total_bytes: totalBytes,
    loaded_at: new Date().toISOString(),
  };
}

export function formatProjectMemoryForInstructions(bundle: ProjectMemoryBundle): string {
  if (bundle.sections.length === 0) {
    return [
      "## Project memory",
      `No CLAUDE.md or AGENTS.md found at ${bundle.root}.`,
      "Create CLAUDE.md in the project root (see Claude Code docs) or call project_context with the project path.",
    ].join("\n");
  }

  const blocks = bundle.sections.map((s) => {
    const note = s.truncated ? " (truncated)" : "";
    return `### ${s.path}${note}\n${s.content}`;
  });

  return [
    "## Project memory (auto-loaded like Claude Code CLAUDE.md)",
    `Root: ${bundle.root}`,
    "Follow these instructions for this project. Use absolute paths under this root.",
    "",
    ...blocks,
  ].join("\n");
}