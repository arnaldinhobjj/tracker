import { assertEquals, assertRejects } from "./test_deps.ts";
import type { JWSRenewalInfo, JWSTransaction, NotificationPayload } from "./apple_types.ts";
import { HttpError } from "./http.ts";
import { type JwsVerifier, verifyAppleJws } from "./jws.ts";
import { processNotification } from "./notifications.ts";
import { MemoryStore } from "./testing/memory_store.ts";
import { createTestChain, signJws, type TestChain } from "./testing/test_pki.ts";

const NOW = new Date("2026-11-18T12:00:00Z");
const DAY = 24 * 3600_000;
const USER = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const BUNDLE = "app.dayledger.DayLedger";

const chain: TestChain = await createTestChain();
const verify: JwsVerifier = <T>(jws: string) => verifyAppleJws<T>(jws, { root: chain.root });

let counter = 0;
function uuid(): string {
  counter++;
  return `00000000-0000-4000-8000-${counter.toString().padStart(12, "0")}`;
}

function tx(overrides: Partial<JWSTransaction> = {}): JWSTransaction {
  return {
    transactionId: "2000000001",
    originalTransactionId: "2000000001",
    bundleId: BUNDLE,
    productId: "app.dayledger.pro.monthly",
    environment: "Production",
    appAccountToken: USER,
    expiresDate: NOW.getTime() + 30 * DAY,
    type: "Auto-Renewable Subscription",
    ...overrides,
  };
}

async function notification(
  type: string,
  options: {
    subtype?: string;
    transaction?: JWSTransaction | null;
    renewal?: JWSRenewalInfo;
    signedDate?: number;
    notificationUUID?: string;
    bundleId?: string;
  } = {},
): Promise<string> {
  const transaction = options.transaction === null ? undefined : options.transaction ?? tx();
  const payload: NotificationPayload = {
    notificationType: type,
    subtype: options.subtype,
    notificationUUID: options.notificationUUID ?? uuid(),
    version: "2.0",
    signedDate: options.signedDate ?? NOW.getTime(),
    data: {
      bundleId: options.bundleId ?? BUNDLE,
      environment: "Production",
      signedTransactionInfo: transaction ? await signJws(transaction, chain) : undefined,
      signedRenewalInfo: options.renewal ? await signJws(options.renewal, chain) : undefined,
    },
  };
  return await signJws(payload, chain);
}

function setup() {
  const store = new MemoryStore();
  store.users.add(USER);
  const deps = { config: { bundleId: BUNDLE }, verify, store, now: NOW };
  return { store, deps };
}

Deno.test("SUBSCRIBED with the free trial offer creates a trial subscription", async () => {
  const { store, deps } = setup();
  const result = await processNotification(
    await notification("SUBSCRIBED", { subtype: "INITIAL_BUY", transaction: tx({ offerType: 1 }) }),
    deps,
  );
  assertEquals(result, "applied");
  const row = store.subscriptions.get(USER)!;
  assertEquals([row.status, row.is_trial], ["trial", true]);
});

Deno.test("notifications are idempotent by notificationUUID", async () => {
  const { store, deps } = setup();
  const id = uuid();
  const signed = await notification("DID_RENEW", { notificationUUID: id });
  assertEquals(await processNotification(signed, deps), "applied");
  store.subscriptions.get(USER)!.status = "expired"; // would be overwritten if re-applied
  assertEquals(await processNotification(signed, deps), "duplicate");
  assertEquals(store.subscriptions.get(USER)!.status, "expired");
  assertEquals(store.notifications.size, 1);
});

Deno.test("unknown users are recorded and acknowledged", async () => {
  const { store, deps } = setup();
  const other = tx({ appAccountToken: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" });
  assertEquals(
    await processNotification(await notification("DID_RENEW", { transaction: other }), deps),
    "unknown_user",
  );
  assertEquals(store.subscriptions.size, 0);
  assertEquals([...store.notifications.values()][0].processedAt !== null, true);
});

Deno.test("users are found by original_transaction_id when there is no appAccountToken", async () => {
  const { store, deps } = setup();
  await processNotification(await notification("SUBSCRIBED"), deps);
  const result = await processNotification(
    await notification("DID_FAIL_TO_RENEW", {
      subtype: "GRACE_PERIOD",
      transaction: tx({ appAccountToken: undefined, expiresDate: NOW.getTime() - DAY }),
      renewal: {
        originalTransactionId: "2000000001",
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: NOW.getTime() + 6 * DAY,
      },
      signedDate: NOW.getTime() + 1,
    }),
    deps,
  );
  assertEquals(result, "applied");
  const row = store.subscriptions.get(USER)!;
  assertEquals(row.status, "grace_period");
  assertEquals(row.expires_at, new Date(NOW.getTime() + 6 * DAY).toISOString());
});

Deno.test("DID_CHANGE_RENEWAL_STATUS only updates auto_renew", async () => {
  const { store, deps } = setup();
  await processNotification(await notification("SUBSCRIBED"), deps);
  const before = { ...store.subscriptions.get(USER)! };
  const result = await processNotification(
    await notification("DID_CHANGE_RENEWAL_STATUS", {
      subtype: "AUTO_RENEW_DISABLED",
      transaction: tx({ transactionId: "999", expiresDate: NOW.getTime() - DAY }),
      renewal: { originalTransactionId: "2000000001", autoRenewStatus: 0 },
    }),
    deps,
  );
  assertEquals(result, "auto_renew_updated");
  assertEquals(store.subscriptions.get(USER), { ...before, auto_renew: false });
});

Deno.test("REFUND and REVOKE end the entitlement", async () => {
  const { store, deps } = setup();
  await processNotification(await notification("SUBSCRIBED"), deps);
  await processNotification(await notification("REFUND", { signedDate: NOW.getTime() + 1 }), deps);
  assertEquals(store.subscriptions.get(USER)!.status, "refunded");
  await processNotification(await notification("REVOKE", { signedDate: NOW.getTime() + 2 }), deps);
  assertEquals(store.subscriptions.get(USER)!.status, "revoked");
});

Deno.test("an older notification arriving late does not overwrite a newer one", async () => {
  const { store, deps } = setup();
  await processNotification(
    await notification("EXPIRED", { subtype: "VOLUNTARY", signedDate: NOW.getTime() }),
    deps,
  );
  const result = await processNotification(
    await notification("DID_RENEW", { signedDate: NOW.getTime() - DAY }),
    deps,
  );
  assertEquals(result, "stale");
  assertEquals(store.subscriptions.get(USER)!.status, "expired");
});

Deno.test("TEST notifications are acknowledged without changes", async () => {
  const { store, deps } = setup();
  assertEquals(
    await processNotification(await notification("TEST", { transaction: null }), deps),
    "no_change",
  );
  assertEquals(store.subscriptions.size, 0);
});

Deno.test("notifications for another app are ignored", async () => {
  const { store, deps } = setup();
  assertEquals(
    await processNotification(await notification("DID_RENEW", { bundleId: "com.other" }), deps),
    "other_app",
  );
  assertEquals(store.notifications.size, 0);
});

Deno.test("a bad signature is a 400 and nothing is stored", async () => {
  const { store, deps } = setup();
  const attacker = await createTestChain();
  const forged = await signJws({
    notificationType: "SUBSCRIBED",
    notificationUUID: uuid(),
    signedDate: NOW.getTime(),
    data: { bundleId: BUNDLE, signedTransactionInfo: await signJws(tx(), attacker) },
  }, attacker);
  const error = await assertRejects(() => processNotification(forged, deps), HttpError);
  assertEquals([error.status, error.code], [400, "invalid_signature"]);
  assertEquals(store.notifications.size, 0);
  assertEquals(store.subscriptions.size, 0);
});
