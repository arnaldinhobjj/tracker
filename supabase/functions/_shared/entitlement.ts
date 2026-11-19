// The entitlement response shared by verify-subscription and entitlement, computed the same way
// as public.has_active_entitlement() in SQL: status in (trial, active, grace_period) and
// expires_at in the future.

import { ENTITLED_STATUSES, type SubscriptionState, type SubscriptionStatus } from "./status.ts";

/** A `subscriptions` row as PostgREST returns it. */
export interface SubscriptionRow {
  user_id: string;
  original_transaction_id: string;
  product_id: string;
  status: SubscriptionStatus;
  expires_at: string;
  is_trial: boolean;
  auto_renew: boolean;
  environment: "Sandbox" | "Production";
  app_account_token: string | null;
  latest_transaction_id: string;
  updated_at?: string;
}

export interface Entitlement {
  active: boolean;
  status: SubscriptionStatus | "none";
  expiresAt: string | null;
  isTrial: boolean;
  productId: string | null;
  autoRenew: boolean | null;
}

export const NO_ENTITLEMENT: Entitlement = {
  active: false,
  status: "none",
  expiresAt: null,
  isTrial: false,
  productId: null,
  autoRenew: null,
};

/** ISO-8601 in UTC without milliseconds, e.g. 2026-11-25T10:00:00Z (the contract's format). */
export function isoSeconds(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function computeEntitlement(
  status: SubscriptionStatus,
  expiresAt: Date,
  isTrial: boolean,
  productId: string,
  autoRenew: boolean,
  now: Date,
): Entitlement {
  return {
    active: ENTITLED_STATUSES.includes(status) && expiresAt.getTime() > now.getTime(),
    status,
    expiresAt: isoSeconds(expiresAt),
    isTrial,
    productId,
    autoRenew,
  };
}

export function entitlementFromRow(row: SubscriptionRow | null, now: Date): Entitlement {
  if (!row) return { ...NO_ENTITLEMENT };
  return computeEntitlement(
    row.status,
    new Date(row.expires_at),
    row.is_trial,
    row.product_id,
    row.auto_renew,
    now,
  );
}

export function entitlementFromState(state: SubscriptionState, now: Date): Entitlement {
  return computeEntitlement(
    state.status,
    state.expiresAt,
    state.isTrial,
    state.productId,
    state.autoRenew,
    now,
  );
}

/** Converts state to the column values written with the service role. */
export function stateToRow(userId: string, state: SubscriptionState): SubscriptionRow {
  return {
    user_id: userId,
    original_transaction_id: state.originalTransactionId,
    product_id: state.productId,
    status: state.status,
    expires_at: state.expiresAt.toISOString(),
    is_trial: state.isTrial,
    auto_renew: state.autoRenew,
    environment: state.environment,
    app_account_token: state.appAccountToken,
    latest_transaction_id: state.latestTransactionId,
  };
}
