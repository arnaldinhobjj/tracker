// TrueLayer token exchange on behalf of the app. TrueLayer's token endpoint needs the client
// secret, which must never ship inside the app, so the app sends only the authorization code or
// the refresh token and this module adds the client credentials.
//
// Tokens pass through and are never stored or logged.

import { HttpError } from "./http.ts";
import { optionalEnv, requireEnv } from "./env.ts";

export type TrueLayerEnvironment = "sandbox" | "live";

export interface TrueLayerConfig {
  clientId: string;
  clientSecret: string;
  environment: TrueLayerEnvironment;
  /** Must match the redirect URI the app used to start the authorization. */
  redirectUri: string;
}

export const DEFAULT_REDIRECT_URI = "dayledger://truelayer-callback";
const MAX_TOKEN_LENGTH = 8192;
const UPSTREAM_TIMEOUT_MS = 15_000;

export function trueLayerConfigFromEnv(): TrueLayerConfig {
  const environment = optionalEnv("TRUELAYER_ENVIRONMENT") ?? "sandbox";
  if (environment !== "sandbox" && environment !== "live") {
    throw new Error("TRUELAYER_ENVIRONMENT must be sandbox or live");
  }
  return {
    clientId: requireEnv("TRUELAYER_CLIENT_ID"),
    clientSecret: requireEnv("TRUELAYER_CLIENT_SECRET"),
    environment,
    redirectUri: optionalEnv("TRUELAYER_REDIRECT_URI") ?? DEFAULT_REDIRECT_URI,
  };
}

export function tokenEndpoint(environment: TrueLayerEnvironment): string {
  return environment === "live"
    ? "https://auth.truelayer.com/connect/token"
    : "https://auth.truelayer-sandbox.com/connect/token";
}

export type TokenGrant =
  | { grantType: "authorization_code"; code: string }
  | { grantType: "refresh_token"; refreshToken: string };

function requireToken(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new HttpError(400, "invalid_request", `${field} is required.`);
  }
  if (value.length > MAX_TOKEN_LENGTH) {
    throw new HttpError(400, "invalid_request", `${field} is too long.`);
  }
  return value.trim();
}

/** Validates the app's request body: `{"grant_type": "...", "code" | "refresh_token": "..."}`. */
export function parseGrant(body: Record<string, unknown>): TokenGrant {
  switch (body.grant_type) {
    case "authorization_code":
      return { grantType: "authorization_code", code: requireToken(body.code, "code") };
    case "refresh_token":
      return {
        grantType: "refresh_token",
        refreshToken: requireToken(body.refresh_token, "refresh_token"),
      };
    default:
      throw new HttpError(
        400,
        "unsupported_grant_type",
        "grant_type must be authorization_code or refresh_token.",
      );
  }
}

/** The form TrueLayer's token endpoint expects, with the client credentials added. */
export function tokenForm(grant: TokenGrant, config: TrueLayerConfig): URLSearchParams {
  const form = new URLSearchParams({
    client_id: config.clientId,
    client_secret: config.clientSecret,
  });
  if (grant.grantType === "authorization_code") {
    form.set("grant_type", "authorization_code");
    form.set("redirect_uri", config.redirectUri);
    form.set("code", grant.code);
  } else {
    form.set("grant_type", "refresh_token");
    form.set("refresh_token", grant.refreshToken);
  }
  return form;
}

export interface TokenResult {
  status: number;
  body: Record<string, unknown>;
}

/** Only the fields the app needs are returned; anything else TrueLayer adds is dropped. */
const TOKEN_FIELDS = ["access_token", "refresh_token", "expires_in", "token_type", "scope"];
const ERROR_FIELDS = ["error", "error_description"];

function pick(source: unknown, fields: string[]): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  if (typeof source !== "object" || source === null) return result;
  for (const field of fields) {
    const value = (source as Record<string, unknown>)[field];
    if (value !== undefined) result[field] = value;
  }
  return result;
}

/**
 * Calls TrueLayer and maps the answer for the app:
 * - 200: the token response (access_token, refresh_token, expires_in, …)
 * - 4xx: TrueLayer's OAuth error (`{"error": "invalid_grant"}`), with the same status, so the app
 *   can tell "reconnect your bank" from other failures
 * - TrueLayer unreachable or 5xx: 502 `upstream_unavailable`
 */
export async function exchangeToken(
  grant: TokenGrant,
  config: TrueLayerConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<TokenResult> {
  let response: Response;
  try {
    response = await fetchImpl(tokenEndpoint(config.environment), {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: tokenForm(grant, config),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch {
    throw new HttpError(502, "upstream_unavailable", "Couldn't reach TrueLayer. Try again.");
  }

  let payload: unknown = undefined;
  try {
    payload = await response.json();
  } catch {
    // Handled below.
  }

  if (response.ok) {
    const body = pick(payload, TOKEN_FIELDS);
    if (typeof body.access_token !== "string") {
      throw new HttpError(502, "upstream_invalid", "TrueLayer returned an unexpected response.");
    }
    return { status: 200, body };
  }
  if (response.status >= 400 && response.status < 500) {
    const body = pick(payload, ERROR_FIELDS);
    if (typeof body.error !== "string") body.error = "invalid_request";
    // 401 from TrueLayer means *our* client credentials are wrong, not the user's session; don't
    // let the app mistake it for an expired DayLedger sign-in.
    return { status: response.status === 401 ? 400 : response.status, body };
  }
  throw new HttpError(502, "upstream_unavailable", "TrueLayer is unavailable. Try again.");
}
