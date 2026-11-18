// Pure mapping from Apple's subscription data to DayLedger's `subscriptions.status`.
// No I/O here, so every rule in docs/backend-contract.md is unit-tested in status_test.ts.

import {
  type JWSRenewalInfo,
  type JWSTransaction,
  OFFER_TYPE_INTRODUCTORY,
} from "./apple_types.ts";

export type SubscriptionStatus =
  | "trial"
  | "active"
  | "grace_period"
  | "billing_retry"
  | "expired"
  | "revoked"
  | "refunded";

export const ENTITLED_STATUSES: readonly SubscriptionStatus[] = ["trial", "active", "grace_period"];

/** The state we store for one subscription (one row of `subscriptions`, minus user/updated_at). */
export interface SubscriptionState {
  originalTransactionId: string;
  latestTransactionId: string;
  productId: string;
  status: SubscriptionStatus;
  expiresAt: Date;
  isTrial: boolean;
  autoRenew: boolean;
  environment: "Sandbox" | "Production";
  appAccountToken: string | null;
}

function isIntroductoryOffer(transaction: JWSTransaction): boolean {
  return transaction.offerType === OFFER_TYPE_INTRODUCTORY;
}

/** `active`, or `trial` when the current period is the introductory offer (our free trial). */
export function activeStatus(transaction: JWSTransaction): SubscriptionStatus {
  return isIntroductoryOffer(transaction) ? "trial" : "active";
}

/**
 * Derives the status from a verified transaction (+ renewal info when known) alone. Used when the
 * App Store Server API is not configured or unreachable, and for notification types the contract
 * does not map explicitly.
 */
export function statusFromTransaction(
  transaction: JWSTransaction,
  renewal: JWSRenewalInfo | undefined,
  now: Date,
): SubscriptionStatus {
  if (transaction.revocationDate !== undefined) return "revoked";
  const expires = transaction.expiresDate;
  if (expires === undefined || expires > now.getTime()) return activeStatus(transaction);
  if (renewal?.isInBillingRetryPeriod) {
    const grace = renewal.gracePeriodExpiresDate;
    return grace !== undefined && grace > now.getTime() ? "grace_period" : "billing_retry";
  }
  return "expired";
}

/**
 * App Store Server API `status` (Get All Subscription Statuses):
 * 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
 */
export function statusFromApiStatus(
  apiStatus: number,
  transaction: JWSTransaction,
  renewal: JWSRenewalInfo | undefined,
  now: Date,
): SubscriptionStatus {
  switch (apiStatus) {
    case 1:
      return activeStatus(transaction);
    case 2:
      return "expired";
    case 3:
      return "billing_retry";
    case 4:
      return "grace_period";
    case 5:
      return "revoked";
    default:
      return statusFromTransaction(transaction, renewal, now);
  }
}

/**
 * Notification types that never change `status`. A newer one of these must not stop a delayed,
 * older status-changing notification from being applied (see app-store-notifications).
 */
export const STATUS_NEUTRAL_NOTIFICATION_TYPES: readonly string[] = [
  "DID_CHANGE_RENEWAL_STATUS",
  "TEST",
  "CONSUMPTION_REQUEST",
  "EXTERNAL_PURCHASE_TOKEN",
];

export type NotificationEffect =
  /** Set the full subscription state with this status. */
  | { kind: "status"; status: SubscriptionStatus }
  /** Only `auto_renew` changes (DID_CHANGE_RENEWAL_STATUS). */
  | { kind: "auto_renew" }
  /** Nothing to apply (e.g. TEST, or no transaction info). */
  | { kind: "none" };

/**
 * Status mapping for App Store Server Notifications V2 (docs/backend-contract.md):
 *   SUBSCRIBED / DID_RENEW               -> active (trial when offerType == 1)
 *   DID_FAIL_TO_RENEW + GRACE_PERIOD     -> grace_period, otherwise billing_retry
 *   EXPIRED / GRACE_PERIOD_EXPIRED       -> expired
 *   REVOKE                               -> revoked
 *   REFUND                               -> refunded
 *   DID_CHANGE_RENEWAL_STATUS            -> auto_renew only
 * Any other type that carries a transaction (e.g. RENEWAL_EXTENDED, REFUND_REVERSED,
 * OFFER_REDEEMED, DID_CHANGE_RENEWAL_PREF) re-derives the status from the transaction itself.
 */
export function notificationEffect(
  notificationType: string,
  subtype: string | undefined,
  transaction: JWSTransaction | undefined,
  renewal: JWSRenewalInfo | undefined,
  now: Date,
): NotificationEffect {
  if (!transaction) return { kind: "none" };
  switch (notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW":
      return { kind: "status", status: activeStatus(transaction) };
    case "DID_FAIL_TO_RENEW":
      return {
        kind: "status",
        status: subtype === "GRACE_PERIOD" ? "grace_period" : "billing_retry",
      };
    case "EXPIRED":
    case "GRACE_PERIOD_EXPIRED":
      return { kind: "status", status: "expired" };
    case "REVOKE":
      return { kind: "status", status: "revoked" };
    case "REFUND":
      return { kind: "status", status: "refunded" };
    case "DID_CHANGE_RENEWAL_STATUS":
      return { kind: "auto_renew" };
    case "TEST":
    case "CONSUMPTION_REQUEST":
    case "EXTERNAL_PURCHASE_TOKEN":
      return { kind: "none" };
    default:
      return { kind: "status", status: statusFromTransaction(transaction, renewal, now) };
  }
}

/**
 * auto_renew from renewal info: autoRenewStatus 1 = on, 0 = off. Without renewal info we keep
 * `fallback` (the stored value, or true for a new row).
 */
export function autoRenewFrom(renewal: JWSRenewalInfo | undefined, fallback: boolean): boolean {
  if (renewal?.autoRenewStatus === 1) return true;
  if (renewal?.autoRenewStatus === 0) return false;
  return fallback;
}

/** expires_at: the grace period expiry while in grace, otherwise the transaction's expiry. */
export function expiresAtFor(
  status: SubscriptionStatus,
  transaction: JWSTransaction,
  renewal: JWSRenewalInfo | undefined,
): Date {
  if (status === "grace_period" && renewal?.gracePeriodExpiresDate !== undefined) {
    return new Date(renewal.gracePeriodExpiresDate);
  }
  if (transaction.expiresDate !== undefined) return new Date(transaction.expiresDate);
  // Auto-renewable subscriptions always carry expiresDate; be conservative if one does not.
  return new Date(transaction.revocationDate ?? transaction.purchaseDate ?? 0);
}

export class UnsupportedEnvironmentError extends Error {
  constructor(environment: string) {
    super(`Unsupported App Store environment ${environment}`);
    this.name = "UnsupportedEnvironmentError";
  }
}

/** Builds the stored state for a verified transaction with an already-decided status. */
export function buildSubscriptionState(
  status: SubscriptionStatus,
  transaction: JWSTransaction,
  renewal: JWSRenewalInfo | undefined,
  autoRenewFallback = true,
): SubscriptionState {
  const environment = transaction.environment;
  if (environment !== "Sandbox" && environment !== "Production") {
    throw new UnsupportedEnvironmentError(String(environment));
  }
  return {
    originalTransactionId: transaction.originalTransactionId,
    latestTransactionId: transaction.transactionId,
    productId: transaction.productId,
    status,
    expiresAt: expiresAtFor(status, transaction, renewal),
    isTrial: transaction.offerType === OFFER_TYPE_INTRODUCTORY,
    autoRenew: autoRenewFrom(renewal, autoRenewFallback),
    environment,
    appAccountToken: transaction.appAccountToken?.toLowerCase() ?? null,
  };
}
