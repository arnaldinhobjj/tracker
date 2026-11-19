// Minimal App Store Server API client: "Get All Subscription Statuses".
// https://developer.apple.com/documentation/appstoreserverapi/get_all_subscription_statuses
// Authentication: https://developer.apple.com/documentation/appstoreserverapi/generating_json_web_tokens_for_api_requests

import type { AppStoreApiCredentials } from "./env.ts";
import type { SubscriptionStatusesResponse } from "./apple_types.ts";
import { base64UrlEncode } from "./jws.ts";

export const PRODUCTION_BASE_URL = "https://api.storekit.itunes.apple.com";
export const SANDBOX_BASE_URL = "https://api.storekit-sandbox.itunes.apple.com";

/** Apple allows tokens up to 60 minutes; we mint a short-lived one per request. */
const TOKEN_LIFETIME_SECONDS = 5 * 60;

export class AppStoreApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "AppStoreApiError";
  }
}

function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  // Secrets set from a shell often arrive with literal "\n" sequences instead of newlines.
  const normalized = pem.replace(/\\n/g, "\n");
  const body = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  if (!body) throw new Error("APPLE_PRIVATE_KEY is empty or not a PKCS#8 PEM (.p8) key");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function importSigningKey(privateKeyPem: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(privateKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/** ES256 JWT with iss/iat/exp/aud/bid as App Store Server API requires. */
export async function createApiToken(
  credentials: AppStoreApiCredentials,
  now: Date = new Date(),
  key?: CryptoKey,
): Promise<string> {
  const signingKey = key ?? await importSigningKey(credentials.privateKey);
  const iat = Math.floor(now.getTime() / 1000);
  const header = { alg: "ES256", kid: credentials.keyId, typ: "JWT" };
  const payload = {
    iss: credentials.issuerId,
    iat,
    exp: iat + TOKEN_LIFETIME_SECONDS,
    aud: "appstoreconnect-v1",
    bid: credentials.bundleId,
  };
  const encoder = new TextEncoder();
  const signingInput = `${base64UrlEncode(encoder.encode(JSON.stringify(header)))}.${
    base64UrlEncode(encoder.encode(JSON.stringify(payload)))
  }`;
  // WebCrypto returns the raw r||s (IEEE P1363) signature, which is exactly JWS ES256 format.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signingKey,
    encoder.encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(signature)}`;
}

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

async function getStatuses(
  baseUrl: string,
  transactionId: string,
  token: string,
  fetchImpl: Fetch,
): Promise<Response> {
  return await fetchImpl(
    `${baseUrl}/inApps/v1/subscriptions/${encodeURIComponent(transactionId)}`,
    { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
  );
}

/**
 * Fetches every subscription status for the customer that owns `transactionId`. Tries
 * production first and falls back to sandbox when production answers 404 (the transaction
 * belongs to a sandbox / TestFlight / App Review purchase).
 */
export async function getAllSubscriptionStatuses(
  transactionId: string,
  credentials: AppStoreApiCredentials,
  fetchImpl: Fetch = fetch,
  now: Date = new Date(),
): Promise<SubscriptionStatusesResponse> {
  const token = await createApiToken(credentials, now);
  let response = await getStatuses(PRODUCTION_BASE_URL, transactionId, token, fetchImpl);
  if (response.status === 404) {
    await response.body?.cancel();
    response = await getStatuses(SANDBOX_BASE_URL, transactionId, token, fetchImpl);
  }
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new AppStoreApiError(
      response.status,
      `App Store Server API returned ${response.status}: ${text.slice(0, 200)}`,
    );
  }
  return await response.json() as SubscriptionStatusesResponse;
}
