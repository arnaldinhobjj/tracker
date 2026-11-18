import { assertEquals, assertRejects } from "./test_deps.ts";
import type { JWSTransaction, SubscriptionStatusesResponse } from "./apple_types.ts";
import { HttpError } from "./http.ts";
import { type JwsVerifier, verifyAppleJws } from "./jws.ts";
import { createTestChain, signJws, type TestChain } from "./testing/test_pki.ts";
import { resolveSubscription, type VerifyTransactionDeps } from "./verify_transaction.ts";

const NOW = new Date("2026-11-18T12:00:00Z");
const DAY = 24 * 3600_000;
const USER = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const BUNDLE = "app.dayledger.DayLedger";

const chain: TestChain = await createTestChain();
const verify: JwsVerifier = <T>(jws: string) => verifyAppleJws<T>(jws, { root: chain.root });

function tx(overrides: Partial<JWSTransaction> = {}): JWSTransaction {
  return {
    transactionId: "2000000001",
    originalTransactionId: "2000000001",
    bundleId: BUNDLE,
    productId: "app.dayledger.pro.monthly",
    environment: "Sandbox",
    appAccountToken: USER.toUpperCase(), // StoreKit may send upper case
    purchaseDate: NOW.getTime() - 1000,
    expiresDate: NOW.getTime() + 7 * DAY,
    type: "Auto-Renewable Subscription",
    offerType: 1,
    ...overrides,
  };
}

function deps(overrides: Partial<VerifyTransactionDeps> = {}): VerifyTransactionDeps {
  return { config: { bundleId: BUNDLE }, verify, now: NOW, ...overrides };
}

async function expectHttpError(promise: Promise<unknown>, status: number, code: string) {
  const error = await assertRejects(() => promise, HttpError);
  assertEquals([error.status, error.code], [status, code]);
}

Deno.test("a verified trial transaction for the caller resolves to trial", async () => {
  const state = await resolveSubscription(await signJws(tx(), chain), USER, deps());
  assertEquals(state.status, "trial");
  assertEquals(state.isTrial, true);
  assertEquals(state.appAccountToken, USER);
  assertEquals(state.expiresAt, new Date(NOW.getTime() + 7 * DAY));
});

Deno.test("appAccountToken of another user is rejected with 403 account_mismatch", async () => {
  const jws = await signJws(tx({ appAccountToken: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }), chain);
  await expectHttpError(resolveSubscription(jws, USER, deps()), 403, "account_mismatch");
  const noToken = await signJws(tx({ appAccountToken: undefined }), chain);
  await expectHttpError(resolveSubscription(noToken, USER, deps()), 403, "account_mismatch");
});

Deno.test("a transaction for another bundle id is rejected", async () => {
  const jws = await signJws(tx({ bundleId: "com.example.other" }), chain);
  await expectHttpError(resolveSubscription(jws, USER, deps()), 403, "bundle_mismatch");
});

Deno.test("an unverifiable or missing transaction is a 400", async () => {
  const other = await createTestChain();
  await expectHttpError(
    resolveSubscription(await signJws(tx(), other), USER, deps()),
    400,
    "invalid_signature",
  );
  await expectHttpError(resolveSubscription(undefined, USER, deps()), 400, "invalid_request");
});

Deno.test("non-subscription purchases are rejected", async () => {
  const jws = await signJws(tx({ type: "Non-Consumable" }), chain);
  await expectHttpError(resolveSubscription(jws, USER, deps()), 400, "not_a_subscription");
});

Deno.test("the App Store Server API status wins over the device's transaction", async () => {
  const renewed = tx({
    transactionId: "2000000009",
    offerType: undefined,
    expiresDate: NOW.getTime() + 30 * DAY,
  });
  const response: SubscriptionStatusesResponse = {
    environment: "Sandbox",
    bundleId: BUNDLE,
    data: [{
      subscriptionGroupIdentifier: "21000000",
      lastTransactions: [{
        originalTransactionId: "2000000001",
        status: 1,
        signedTransactionInfo: await signJws(renewed, chain),
        signedRenewalInfo: await signJws(
          { originalTransactionId: "2000000001", autoRenewStatus: 0 },
          chain,
        ),
      }],
    }],
  };
  const state = await resolveSubscription(
    await signJws(tx(), chain),
    USER,
    deps({ fetchStatuses: () => Promise.resolve(response) }),
  );
  assertEquals(state.status, "active");
  assertEquals(state.latestTransactionId, "2000000009");
  assertEquals(state.autoRenew, false);
  assertEquals(state.isTrial, false);
});

Deno.test("API status 4 (grace period) uses the grace period expiry", async () => {
  const grace = NOW.getTime() + 6 * DAY;
  const response: SubscriptionStatusesResponse = {
    environment: "Sandbox",
    bundleId: BUNDLE,
    data: [{
      subscriptionGroupIdentifier: "21000000",
      lastTransactions: [{
        originalTransactionId: "2000000001",
        status: 4,
        signedTransactionInfo: await signJws(tx({ expiresDate: NOW.getTime() - DAY }), chain),
        signedRenewalInfo: await signJws(
          { originalTransactionId: "2000000001", gracePeriodExpiresDate: grace },
          chain,
        ),
      }],
    }],
  };
  const state = await resolveSubscription(
    await signJws(tx(), chain),
    USER,
    deps({ fetchStatuses: () => Promise.resolve(response) }),
  );
  assertEquals(state.status, "grace_period");
  assertEquals(state.expiresAt.getTime(), grace);
});

Deno.test("an unreachable App Store Server API falls back to the verified transaction", async () => {
  const logs: string[] = [];
  const state = await resolveSubscription(
    await signJws(tx({ offerType: undefined }), chain),
    USER,
    deps({
      fetchStatuses: () => Promise.reject(new Error("network down")),
      log: (m) => logs.push(m),
    }),
  );
  assertEquals(state.status, "active");
  assertEquals(logs.length, 1);
});
