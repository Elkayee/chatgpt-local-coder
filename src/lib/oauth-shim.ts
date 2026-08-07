/**
 * OAuth 2.1 "shim" — lightweight endpoints that satisfy
 * Claude Web's OAuth requirement without real credentials.
 *
 * Implements:
 *   RFC 8414  — Authorization Server Metadata
 *   RFC 9728  — OAuth Protected Resource Metadata
 *   RFC 7591  — Dynamic Client Registration
 *   PKCE (S256) verification
 *
 * All tokens are opaque UUIDs. The MCP endpoints do NOT
 * validate them — the server remains effectively open so
 * ChatGPT (no-auth) keeps working alongside Claude Web.
 */

import { Router, type Request, type Response } from "express";
import crypto from "crypto";

// ── Types ─────────────────────────────────────────────────

interface AuthCode {
  clientId: string;
  redirectUri: string;
  codeChallenge?: string;
  codeChallengeMethod?: string;
  expiresAt: number;
}

// ── In-memory stores ──────────────────────────────────────

const authCodes = new Map<string, AuthCode>();

// Clean up expired codes every 60 s
const cleanupTimer = setInterval(() => {
  const now = Date.now();
  for (const [code, data] of authCodes) {
    if (data.expiresAt < now) authCodes.delete(code);
  }
}, 60_000);
cleanupTimer.unref(); // don't keep process alive

// ── Helpers ───────────────────────────────────────────────

/** Derive the public-facing base URL from reverse-proxy / tunnel headers. */
function getIssuerUrl(req: Request): string {
  const proto =
    (req.headers["x-forwarded-proto"] as string)?.split(",")[0]?.trim() ||
    "https";
  const host =
    (req.headers["x-forwarded-host"] as string)?.split(",")[0]?.trim() ||
    req.headers.host ||
    "localhost:3000";
  return `${proto}://${host}`;
}

/** Verify PKCE S256 or plain challenge. */
function verifyPkce(
  verifier: string,
  challenge: string,
  method: string,
): boolean {
  if (method === "S256") {
    const hash = crypto
      .createHash("sha256")
      .update(verifier)
      .digest("base64url");
    return hash === challenge;
  }
  // plain
  return verifier === challenge;
}

// ── Router factory ────────────────────────────────────────

export function createOAuthShimRouter(): Router {
  const router = Router();

  /* ─── RFC 9728 — Protected Resource Metadata ─────────── */
  router.get(
    ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/*"],
    (req: Request, res: Response) => {
      const issuer = getIssuerUrl(req);
      res.json({
        resource: issuer,
        authorization_servers: [issuer],
        bearer_methods_supported: ["header"],
        scopes_supported: ["mcp:tools"],
      });
    },
  );

  /* ─── RFC 8414 — Authorization Server Metadata ───────── */
  router.get(
    ["/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/*"],
    (req: Request, res: Response) => {
      const issuer = getIssuerUrl(req);
      res.json({
        issuer,
        authorization_endpoint: `${issuer}/oauth/authorize`,
        token_endpoint: `${issuer}/oauth/token`,
        registration_endpoint: `${issuer}/oauth/register`,
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: [
          "none",
          "client_secret_post",
        ],
        code_challenge_methods_supported: ["S256"],
        scopes_supported: ["mcp:tools"],
      });
    },
  );

  /* ─── RFC 7591 — Dynamic Client Registration ─────────── */
  router.post("/oauth/register", (req: Request, res: Response) => {
    const clientId = `client_${crypto.randomUUID()}`;
    const clientSecret = `secret_${crypto.randomUUID()}`;
    const redirectUris: string[] = req.body?.redirect_uris ?? [];

    console.log(`[OAuth] Client registered: ${clientId}`);

    res.status(201).json({
      client_id: clientId,
      client_secret: clientSecret,
      client_id_issued_at: Math.floor(Date.now() / 1000),
      client_secret_expires_at: 0, // never expires
      redirect_uris: redirectUris,
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "client_secret_post",
    });
  });

  /* ─── Authorization endpoint (auto-approve) ──────────── */
  router.get("/oauth/authorize", (req: Request, res: Response) => {
    const {
      client_id,
      redirect_uri,
      response_type,
      state,
      code_challenge,
      code_challenge_method,
    } = req.query as Record<string, string>;

    if (response_type !== "code") {
      res.status(400).json({ error: "unsupported_response_type" });
      return;
    }

    if (!redirect_uri) {
      res.status(400).json({
        error: "invalid_request",
        error_description: "redirect_uri is required",
      });
      return;
    }

    // Generate auth code, store with PKCE challenge
    const code = crypto.randomUUID();
    authCodes.set(code, {
      clientId: client_id || "unknown",
      redirectUri: redirect_uri,
      codeChallenge: code_challenge,
      codeChallengeMethod: code_challenge_method || "plain",
      expiresAt: Date.now() + 5 * 60 * 1000, // 5 minutes
    });

    console.log(
      `[OAuth] Authorize → auto-approve → redirect ${redirect_uri.slice(0, 60)}…`,
    );

    // Auto-approve: redirect back immediately with code + state
    const url = new URL(redirect_uri);
    url.searchParams.set("code", code);
    if (state) url.searchParams.set("state", state);

    res.redirect(302, url.toString());
  });

  /* ─── Token endpoint ─────────────────────────────────── */
  router.post("/oauth/token", (req: Request, res: Response) => {
    const { grant_type, code, code_verifier } = req.body;

    // ── authorization_code ──
    if (grant_type === "authorization_code") {
      const stored = authCodes.get(code);
      if (!stored) {
        res.status(400).json({
          error: "invalid_grant",
          error_description: "Invalid or expired authorization code",
        });
        return;
      }

      // PKCE verification
      if (stored.codeChallenge) {
        if (!code_verifier) {
          res.status(400).json({
            error: "invalid_request",
            error_description: "code_verifier is required",
          });
          return;
        }
        if (
          !verifyPkce(
            code_verifier,
            stored.codeChallenge,
            stored.codeChallengeMethod || "plain",
          )
        ) {
          res.status(400).json({
            error: "invalid_grant",
            error_description: "PKCE verification failed",
          });
          return;
        }
      }

      // Consume code (one-time use)
      authCodes.delete(code);

      const accessToken = `mcp_${crypto.randomUUID()}`;
      const refreshToken = `refresh_${crypto.randomUUID()}`;

      console.log("[OAuth] Token issued (authorization_code)");

      res.json({
        access_token: accessToken,
        token_type: "Bearer",
        expires_in: 86400, // 24 hours
        refresh_token: refreshToken,
        scope: "mcp:tools",
      });
      return;
    }

    // ── refresh_token ──
    if (grant_type === "refresh_token") {
      const accessToken = `mcp_${crypto.randomUUID()}`;
      const refreshToken = `refresh_${crypto.randomUUID()}`;

      console.log("[OAuth] Token refreshed");

      res.json({
        access_token: accessToken,
        token_type: "Bearer",
        expires_in: 86400,
        refresh_token: refreshToken,
        scope: "mcp:tools",
      });
      return;
    }

    res.status(400).json({ error: "unsupported_grant_type" });
  });

  return router;
}
