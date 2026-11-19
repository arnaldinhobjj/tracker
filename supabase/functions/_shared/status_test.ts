import { assertEquals, assertThrows } from "./test_deps.ts";
import type { JWSRenewalInfo, JWSTransaction } from "./apple_types.ts";
import {
  autoRenewFrom,
  buildSubscriptionState,
  expiresAtFor,
  notificationEffect,
  statusFromApiStatus,
  statusFromTransaction,
  UnsupportedEnvironmentError,
} from "./status.ts";

const NOW = new Date("2026-11-18T12:00:00Z");
const HOUR = 3600_000;

function tx(overrides: Partial<JWSTransaction> = {}): JWSTransaction {
  return {
    transactionId: "2000000002",
    originalTransactionId: "2000000001",
    bundleId: "app.dayledger.DayLedger",
    productId: "app.dayledger.pro.monthly",
    environment: "Sandbox",
    appAccountToken: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
    purchaseDate: NOW.getTime() - HOUR,
    expiresDate: NOW.getTime() + 7 * 24 * HOUR,
    type: "Auto-Renewable Subscription",
    ...overrides,
  };
}

const effect = (
  type: string,
  subtype?: string,
  t: JWSTransaction | undefined = tx(),
  r?: JWSRenewalInfo,
) => notificationEffect(type, subtype, t, r, NOW);

Deno.test("SUBSCRIBED and DID_RENEW map to active", () => {
  assertEquals(effect("SUBSCRIBED", "RESUBSCRIBE"), { kind: "status", status: "active" });
  assertEquals(effect("DID_RENEW"), { kind: "status", status: "active" });
  assertEquals(effect("DID_RENEW", "BILLING_RECOVERY"), { kind: "status", status: "active" });
});

Deno.test("offerType 1 (introductory free trial) on an active period maps to trial", () => {
  const trial = tx({ offerType: 1, offerDiscountType: "FREE_TRIAL" });
  assertEquals(effect("SUBSCRIBED", "INITIAL_BUY", trial), { kind: "status", status: "trial" });
  assertEquals(effect("DID_RENEW", undefined, trial), { kind: "status", status: "trial" });
  // Promotional (2) and offer-code (3) offers are not the trial.
  assertEquals(effect("SUBSCRIBED", undefined, tx({ offerType: 2 })), {
    kind: "status",
    status: "active",
  });
  assertEquals(statusFromTransaction(trial, undefined, NOW), "trial");
  assertEquals(statusFromApiStatus(1, trial, undefined, NOW), "trial");
});

Deno.test("DID_FAIL_TO_RENEW maps to grace_period with GRACE_PERIOD, else billing_retry", () => {
  assertEquals(effect("DID_FAIL_TO_RENEW", "GRACE_PERIOD"), {
    kind: "status",
    status: "grace_period",
  });
  assertEquals(effect("DID_FAIL_TO_RENEW"), { kind: "status", status: "billing_retry" });
});

Deno.test("EXPIRED, GRACE_PERIOD_EXPIRED, REVOKE and REFUND", () => {
  assertEquals(effect("EXPIRED", "VOLUNTARY"), { kind: "status", status: "expired" });
  assertEquals(effect("EXPIRED", "BILLING_RETRY"), { kind: "status", status: "expired" });
  assertEquals(effect("GRACE_PERIOD_EXPIRED"), { kind: "status", status: "expired" });
  assertEquals(effect("REVOKE"), { kind: "status", status: "revoked" });
  assertEquals(effect("REFUND"), { kind: "status", status: "refunded" });
});

Deno.test("DID_CHANGE_RENEWAL_STATUS only changes auto_renew; TEST changes nothing", () => {
  assertEquals(effect("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"), { kind: "auto_renew" });
  assertEquals(notificationEffect("TEST", undefined, undefined, undefined, NOW), { kind: "none" });
  assertEquals(notificationEffect("SUBSCRIBED", undefined, undefined, undefined, NOW), {
    kind: "none",
  });
});

Deno.test("unmapped types re-derive the status from the transaction", () => {
  assertEquals(effect("RENEWAL_EXTENDED"), { kind: "status", status: "active" });
  assertEquals(effect("REFUND_REVERSED"), { kind: "status", status: "active" });
  assertEquals(effect("PRICE_INCREASE", undefined, tx({ expiresDate: NOW.getTime() - HOUR })), {
    kind: "status",
    status: "expired",
  });
});

Deno.test("statusFromTransaction covers expiry, billing retry, grace and revocation", () => {
  const lapsed = tx({ expiresDate: NOW.getTime() - HOUR });
  assertEquals(statusFromTransaction(tx(), undefined, NOW), "active");
  assertEquals(statusFromTransaction(lapsed, undefined, NOW), "expired");
  assertEquals(
    statusFromTransaction(
      lapsed,
      { originalTransactionId: "1", isInBillingRetryPeriod: true },
      NOW,
    ),
    "billing_retry",
  );
  assertEquals(
    statusFromTransaction(lapsed, {
      originalTransactionId: "1",
      isInBillingRetryPeriod: true,
      gracePeriodExpiresDate: NOW.getTime() + HOUR,
    }, NOW),
    "grace_period",
  );
  assertEquals(
    statusFromTransaction(tx({ revocationDate: NOW.getTime() }), undefined, NOW),
    "revoked",
  );
});

Deno.test("App Store Server API status codes", () => {
  assertEquals(statusFromApiStatus(1, tx(), undefined, NOW), "active");
  assertEquals(statusFromApiStatus(2, tx(), undefined, NOW), "expired");
  assertEquals(statusFromApiStatus(3, tx(), undefined, NOW), "billing_retry");
  assertEquals(statusFromApiStatus(4, tx(), undefined, NOW), "grace_period");
  assertEquals(statusFromApiStatus(5, tx(), undefined, NOW), "revoked");
});

Deno.test("expires_at is the grace period expiry while in grace", () => {
  const grace = NOW.getTime() + 16 * 24 * HOUR;
  const renewal = { originalTransactionId: "1", gracePeriodExpiresDate: grace };
  assertEquals(expiresAtFor("grace_period", tx(), renewal).getTime(), grace);
  assertEquals(expiresAtFor("active", tx(), renewal).getTime(), tx().expiresDate);
});

Deno.test("auto_renew follows renewal info, else the fallback", () => {
  assertEquals(autoRenewFrom({ originalTransactionId: "1", autoRenewStatus: 0 }, true), false);
  assertEquals(autoRenewFrom({ originalTransactionId: "1", autoRenewStatus: 1 }, false), true);
  assertEquals(autoRenewFrom(undefined, false), false);
});

Deno.test("buildSubscriptionState fills every column and rejects Xcode environments", () => {
  const state = buildSubscriptionState("trial", tx({ offerType: 1 }), undefined);
  assertEquals(state, {
    originalTransactionId: "2000000001",
    latestTransactionId: "2000000002",
    productId: "app.dayledger.pro.monthly",
    status: "trial",
    expiresAt: new Date(tx().expiresDate!),
    isTrial: true,
    autoRenew: true,
    environment: "Sandbox",
    appAccountToken: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  });
  assertThrows(
    () => buildSubscriptionState("active", tx({ environment: "Xcode" }), undefined),
    UnsupportedEnvironmentError,
  );
});
