import { assertEquals } from "./test_deps.ts";
import { entitlementFromRow, isoSeconds, type SubscriptionRow } from "./entitlement.ts";

const NOW = new Date("2026-11-18T10:00:00Z");

function row(overrides: Partial<SubscriptionRow> = {}): SubscriptionRow {
  return {
    user_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    original_transaction_id: "2000000001",
    product_id: "app.dayledger.pro.monthly",
    status: "trial",
    expires_at: "2026-11-25T10:00:00.000+00:00",
    is_trial: true,
    auto_renew: true,
    environment: "Production",
    app_account_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    latest_transaction_id: "2000000001",
    ...overrides,
  };
}

Deno.test("no row means no entitlement", () => {
  assertEquals(entitlementFromRow(null, NOW), {
    active: false,
    status: "none",
    expiresAt: null,
    isTrial: false,
    productId: null,
    autoRenew: null,
  });
});

Deno.test("a trial row produces the contract's response shape", () => {
  assertEquals(entitlementFromRow(row(), NOW), {
    active: true,
    status: "trial",
    expiresAt: "2026-11-25T10:00:00Z",
    isTrial: true,
    productId: "app.dayledger.pro.monthly",
    autoRenew: true,
  });
});

Deno.test("trial, active and grace_period are active only before expires_at", () => {
  for (const status of ["trial", "active", "grace_period"] as const) {
    assertEquals(entitlementFromRow(row({ status }), NOW).active, true, status);
    assertEquals(
      entitlementFromRow(row({ status, expires_at: "2026-11-18T09:59:59Z" }), NOW).active,
      false,
      `${status} past expiry`,
    );
    assertEquals(
      entitlementFromRow(row({ status, expires_at: NOW.toISOString() }), NOW).active,
      false,
      `${status} at exactly expires_at`,
    );
  }
});

Deno.test("billing_retry, expired, revoked and refunded are never active", () => {
  for (const status of ["billing_retry", "expired", "revoked", "refunded"] as const) {
    const e = entitlementFromRow(row({ status, is_trial: false }), NOW);
    assertEquals(e.active, false, status);
    assertEquals(e.status, status);
  }
});

Deno.test("isoSeconds drops milliseconds", () => {
  assertEquals(isoSeconds(new Date("2026-11-25T10:00:00.123Z")), "2026-11-25T10:00:00Z");
});
