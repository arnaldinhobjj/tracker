import { assertEquals, assertRejects, assertThrows } from "./test_deps.ts";
import { HttpError } from "./http.ts";
import {
  DEFAULT_REDIRECT_URI,
  exchangeToken,
  parseGrant,
  tokenEndpoint,
  tokenForm,
  type TrueLayerConfig,
} from "./truelayer.ts";

const config: TrueLayerConfig = {
  clientId: "sandbox-dayledger-1",
  clientSecret: "s3cret",
  environment: "sandbox",
  redirectUri: DEFAULT_REDIRECT_URI,
};

function fakeFetch(
  status: number,
  body: unknown,
  seen: { url?: string; init?: RequestInit } = {},
): typeof fetch {
  return ((url: string | URL | Request, init?: RequestInit) => {
    seen.url = String(url);
    seen.init = init;
    const text = typeof body === "string" ? body : JSON.stringify(body);
    return Promise.resolve(new Response(text, { status }));
  }) as typeof fetch;
}

Deno.test("parseGrant accepts the two grant types and rejects anything else", () => {
  assertEquals(parseGrant({ grant_type: "authorization_code", code: " abc " }), {
    grantType: "authorization_code",
    code: "abc",
  });
  assertEquals(parseGrant({ grant_type: "refresh_token", refresh_token: "r1" }), {
    grantType: "refresh_token",
    refreshToken: "r1",
  });
  assertThrows(() => parseGrant({ grant_type: "client_credentials" }), HttpError);
  assertThrows(() => parseGrant({ grant_type: "authorization_code" }), HttpError);
  assertThrows(() => parseGrant({ grant_type: "refresh_token", refresh_token: "" }), HttpError);
  assertThrows(
    () => parseGrant({ grant_type: "refresh_token", refresh_token: "x".repeat(9000) }),
    HttpError,
  );
});

Deno.test("the form carries the server's credentials and redirect URI, never the app's", () => {
  const code = tokenForm({ grantType: "authorization_code", code: "abc" }, config);
  assertEquals(code.get("client_id"), "sandbox-dayledger-1");
  assertEquals(code.get("client_secret"), "s3cret");
  assertEquals(code.get("redirect_uri"), "dayledger://truelayer-callback");
  assertEquals(code.get("grant_type"), "authorization_code");
  assertEquals(code.get("code"), "abc");

  const refresh = tokenForm({ grantType: "refresh_token", refreshToken: "r1" }, config);
  assertEquals(refresh.get("grant_type"), "refresh_token");
  assertEquals(refresh.get("refresh_token"), "r1");
  assertEquals(refresh.get("redirect_uri"), null);
});

Deno.test("token endpoint follows the environment", () => {
  assertEquals(tokenEndpoint("sandbox"), "https://auth.truelayer-sandbox.com/connect/token");
  assertEquals(tokenEndpoint("live"), "https://auth.truelayer.com/connect/token");
});

Deno.test("a successful exchange returns only the token fields", async () => {
  const seen: { url?: string; init?: RequestInit } = {};
  const result = await exchangeToken(
    { grantType: "authorization_code", code: "abc" },
    config,
    fakeFetch(200, {
      access_token: "a",
      refresh_token: "r",
      expires_in: 3600,
      token_type: "Bearer",
      internal: "dropped",
    }, seen),
  );
  assertEquals(result.status, 200);
  assertEquals(result.body, {
    access_token: "a",
    refresh_token: "r",
    expires_in: 3600,
    token_type: "Bearer",
  });
  assertEquals(seen.url, "https://auth.truelayer-sandbox.com/connect/token");
  assertEquals(seen.init?.method, "POST");
  assertEquals((seen.init?.body as URLSearchParams).get("client_secret"), "s3cret");
});

Deno.test("OAuth errors pass through so the app can ask to reconnect", async () => {
  const result = await exchangeToken(
    { grantType: "refresh_token", refreshToken: "old" },
    config,
    fakeFetch(400, { error: "invalid_grant", error_description: "expired", trace: "x" }),
  );
  assertEquals(result.status, 400);
  assertEquals(result.body, { error: "invalid_grant", error_description: "expired" });
});

Deno.test("TrueLayer rejecting our client credentials is not reported as 401", async () => {
  const result = await exchangeToken(
    { grantType: "refresh_token", refreshToken: "r" },
    config,
    fakeFetch(401, { error: "invalid_client" }),
  );
  assertEquals(result.status, 400);
  assertEquals(result.body.error, "invalid_client");
});

Deno.test("a 4xx without a JSON body still has an error code", async () => {
  const result = await exchangeToken(
    { grantType: "refresh_token", refreshToken: "r" },
    config,
    fakeFetch(429, "slow down"),
  );
  assertEquals(result.status, 429);
  assertEquals(result.body.error, "invalid_request");
});

Deno.test("upstream failures become 502", async () => {
  const unreachable = (() => Promise.reject(new TypeError("dns"))) as typeof fetch;
  for (const fetchImpl of [fakeFetch(503, "down"), unreachable, fakeFetch(200, { nope: 1 })]) {
    const error = await assertRejects(
      () => exchangeToken({ grantType: "refresh_token", refreshToken: "r" }, config, fetchImpl),
      HttpError,
    );
    assertEquals(error.status, 502);
  }
});
