import fs from "fs/promises";
import path from "path";

export type AuditStatus = "ok" | "error" | "blocked" | "dry-run";

export interface AuditEvent {
  tool: string;
  action: string;
  target?: string;
  status?: AuditStatus;
  details?: Record<string, unknown>;
}

const auditPath = process.env.AUDIT_LOG_PATH || path.resolve(process.cwd(), ".mcp-audit.log");

export async function audit(event: AuditEvent): Promise<void> {
  const record = {
    time: new Date().toISOString(),
    pid: process.pid,
    ...event,
  };

  try {
    await fs.mkdir(path.dirname(auditPath), { recursive: true });
    await fs.appendFile(auditPath, JSON.stringify(record) + "\n", "utf-8");
  } catch {
    // Audit must never break the requested tool call.
  }
}

export function getAuditPath(): string {
  return auditPath;
}
