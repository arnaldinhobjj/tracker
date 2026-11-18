import { assert, assertEquals, assertRejects } from "./test_deps.ts";
import {
  AppStoreApiError,
  createApiToken,
  getAllSubscriptionStatuses,
  PRODUCTION_BASE_URL,
  SANDBOX_BASE_URL,
} from "./app_store_api.ts";
import type { SubscriptionStatusesResponse } from "./apple_types.ts";
import type { AppStoreApiCredentials } from "./env.ts";
import { base64UrlDecode, base64UrlEncode } from "./jws.ts";

const keys = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
) as CryptoKeyPair;
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n")
}\n-----END PRIVATE KEY-----`;

const credentials: AppStoreApiCredentials = {
  issuerId: "57246542-96fe-1a63-e053-0824d011072a",
  keyId: "2X9R4HXF34",
  // Escaped newlines, as `supabase secrets set` from a shell often stores them.
  privateKey: pem.replace(/\n/g, "\\n"),
  bundleId: "app.dayledger.DayLedger",
};

function decode(segment: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment)));
}

Deno.test("API token is an ES256 JWT with the claims Apple requires", async () => {
  const now = new Date("2026-11-18T12:00:00Z");
  const token = await createApiToken(credentials, now);
  const [h, p, s] = token.split(".");
  assertEquals(decode(h), { alg: "ES256", kid: "2X9R4HXF34", typ: "JWT" });
  const iat = Math.floor(now.getTime() / 1000);
  assertEquals(decode(p), {
    iss: credentials.issuerId,
    iat,
    exp: iat + 300,
    aud: "appstoreconnect-v1",
    bid: "app.dayledger.DayLedger",
  });
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    keys.publicKey,
    base64UrlDecode(s),
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert(valid, "signature verifies with the public key");
  assertEquals(base64UrlEncode(base64UrlDecode(s)), s);
});

Deno.test("status lookup tries production first, then sandbox on 404", async () => {
  const calls: string[] = [];
  const body: SubscriptionStatusesResponse = {
    environment: "Sandbox",
    bundleId: credentials.bundleId,
    data: [],
  };
  const fakeFetch = (url: string, init?: RequestInit) => {
    calls.push(url);
    assert(String(new Headers(init?.headers).get("Authorization")).startsWith("Bearer "));
    return Promise.resolve(
      url.startsWith(PRODUCTION_BASE_URL)
        ? new Response("{}", { status: 404 })
        : new Response(JSON.stringify(body), { status: 200 }),
    );
  };
  const result = await getAllSubscriptionStatuses("2000000001", credentials, fakeFetch);
  assertEquals(result, body);
  assertEquals(calls, [
    `${PRODUCTION_BASE_URL}/inApps/v1/subscriptions/2000000001`,
    `${SANDBOX_BASE_URL}/inApps/v1/subscriptions/2000000001`,
  ]);
});

Deno.test("production success does not call sandbox; errors surface", async () => {
  const calls: string[] = [];
  const ok = (url: string) => {
    calls.push(url);
    return Promise.resolve(new Response(JSON.stringify({ data: [] }), { status: 200 }));
  };
  await getAllSubscriptionStatuses("1", credentials, ok);
  assertEquals(calls.length, 1);

  const unauthorized = () => Promise.resolve(new Response("nope", { status: 401 }));
  const error = await assertRejects(
    () => getAllSubscriptionStatuses("1", credentials, unauthorized),
    AppStoreApiError,
  );
  assertEquals(error.status, 401);
});
