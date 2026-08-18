import path from "path";

import type { UpstreamServerConfig } from "./mcp-upstream-config.js";
import type { McpUpstreamManager } from "./mcp-upstream-manager.js";

export interface ContextEngineRepo {
  repo: string;
  mcp_repo_id: string;
  file_count?: number;
  last_indexed_at?: string | null;
  state?: string;
}

interface ContextEngineReposResponse {
  repos?: ContextEngineRepo[];
}

export interface ContextEngineDiscoveryOptions {
  apiBaseUrl: string;
  mcpBaseUrl: string;
  intervalMs: number;
  exclude: Set<string>;
}

function cleanBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function cleanToolPart(value: string): string {
  return value.replace(/[^a-zA-Z0-9_-]/g, "_").replace(/^_+|_+$/g, "") || "repo";
}

function endpointFor(baseUrl: string, repoId: string): string {
  return `${cleanBaseUrl(baseUrl)}/mcp-repo/${repoId}`;
}

function isIndexed(repo: ContextEngineRepo): boolean {
  if (repo.state === "not_indexed") return false;
  return (repo.file_count ?? 0) > 0 || Boolean(repo.last_indexed_at);
}

function sameRepoEndpoint(server: UpstreamServerConfig, repoId: string): boolean {
  if (server.transport !== "http" || !server.url) return false;
  return cleanBaseUrl(server.url).endsWith(`/mcp-repo/${repoId}`);
}

function nextUniqueName(base: string, used: Set<string>): string {
  if (!used.has(base)) {
    used.add(base);
    return base;
  }
  let suffix = 2;
  while (used.has(`${base}_${suffix}`)) suffix += 1;
  const value = `${base}_${suffix}`;
  used.add(value);
  return value;
}

export function planContextEngineServers(
  repos: ContextEngineRepo[],
  existing: UpstreamServerConfig[],
  options: Pick<ContextEngineDiscoveryOptions, "mcpBaseUrl" | "exclude">
): UpstreamServerConfig[] {
  const additions: UpstreamServerConfig[] = [];
  const usedIds = new Set(existing.map((server) => server.id));
  const usedPrefixes = new Set(existing.map((server) => server.tool_prefix ?? server.id));

  for (const repo of repos) {
    const repoPath = repo.repo?.trim();
    const repoId = repo.mcp_repo_id?.trim();
    if (!repoPath || !repoId || !isIndexed(repo)) continue;
    if (options.exclude.has(repoPath) || options.exclude.has(repoId)) continue;
    if ([...existing, ...additions].some((server) => sameRepoEndpoint(server, repoId))) continue;

    const basename = path.basename(repoPath.replace(/\\/g, "/"));
    const prefix = nextUniqueName(cleanToolPart(basename || repoId), usedPrefixes);
    const id = nextUniqueName(`codebase-retrieval-${prefix}`, usedIds);

    additions.push({
      id,
      name: id,
      enabled: true,
      transport: "http",
      url: endpointFor(options.mcpBaseUrl, repoId),
      tool_prefix: prefix,
      expose: "allowlist",
      tools: ["codebase-retrieval", "file-retrieval"],
    });
  }

  return additions;
}

export function contextEngineDiscoveryOptionsFromEnv(
  env: NodeJS.ProcessEnv = process.env
): ContextEngineDiscoveryOptions | null {
  const configured = env.CONTEXT_ENGINE_DISCOVERY_URL?.trim();
  if (!configured) return null;

  const apiBaseUrl = cleanBaseUrl(configured);
  const mcpBaseUrl = cleanBaseUrl(env.CONTEXT_ENGINE_MCP_BASE_URL?.trim() || apiBaseUrl);
  const intervalSecRaw = Number.parseInt(env.CONTEXT_ENGINE_DISCOVERY_INTERVAL_SEC || "30", 10);
  const intervalSec = Number.isFinite(intervalSecRaw) ? Math.max(5, intervalSecRaw) : 30;
  const exclude = new Set(
    (env.CONTEXT_ENGINE_DISCOVERY_EXCLUDE || "")
      .split(";")
      .map((value) => value.trim())
      .filter(Boolean)
  );

  return {
    apiBaseUrl,
    mcpBaseUrl,
    intervalMs: intervalSec * 1000,
    exclude,
  };
}

export async function syncContextEngineRepos(
  manager: McpUpstreamManager,
  options: ContextEngineDiscoveryOptions
): Promise<string[]> {
  const response = await fetch(`${options.apiBaseUrl}/api/repos`, {
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) {
    throw new Error(`Context Engine discovery HTTP ${response.status}`);
  }

  const body = (await response.json()) as ContextEngineReposResponse;
  const repos = Array.isArray(body.repos) ? body.repos : [];
  const current = manager.getConfig();
  const additions = planContextEngineServers(repos, current.servers, options);
  if (additions.length === 0) return [];

  await manager.updateConfig({
    version: 1,
    servers: [...current.servers, ...additions],
  });
  return additions.map((server) => server.id);
}

export async function startContextEngineDiscovery(
  manager: McpUpstreamManager,
  options = contextEngineDiscoveryOptionsFromEnv()
): Promise<() => void> {
  if (!options) return () => {};

  let syncing = false;
  const sync = async (): Promise<void> => {
    if (syncing) return;
    syncing = true;
    try {
      const added = await syncContextEngineRepos(manager, options);
      if (added.length > 0) {
        console.log(`[MCP] Context Engine discovery added: ${added.join(", ")}`);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`[MCP] Context Engine discovery failed: ${message}`);
    } finally {
      syncing = false;
    }
  };

  await sync();
  const timer = setInterval(() => void sync(), options.intervalMs);
  timer.unref();
  console.log(
    `[MCP] Context Engine discovery: ${options.apiBaseUrl}/api/repos every ${Math.round(options.intervalMs / 1000)}s`
  );

  return () => clearInterval(timer);
}
