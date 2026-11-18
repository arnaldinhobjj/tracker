// Core of POST verify-subscription, free of HTTP and database code so it can be unit-tested.

import type {
  JWSRenewalInfo,
  JWSTransaction,
  SubscriptionStatusesResponse,
} from "./apple_types.ts";
import type { AppleConfig } from "./env.ts";
import { HttpError } from "./http.ts";
import { JwsVerificationError, type JwsVerifier } from "./jws.ts";
import {
  buildSubscriptionState,
  statusFromApiStatus,
  statusFromTransaction,
  type SubscriptionState,
  type SubscriptionStatus,
  UnsupportedEnvironmentError,
} from "./status.ts";

export const AUTO_RENEWABLE_TYPE = "Auto-Renewable Subscription";

export interface VerifyTransactionDeps {
  config: AppleConfig;
  verify: JwsVerifier;
  /** App Store Server API lookup; omitted when the API secrets are not configured. */
  fetchStatuses?: (transactionId: string) => Promise<SubscriptionStatusesResponse>;
  now: Date;
  log?: (message: string, error?: unknown) => void;
}

async function verifyOr400<T>(verify: JwsVerifier, jws: string, what: string): Promise<T> {
  try {
    return await verify<T>(jws);
  } catch (error) {
    if (error instanceof JwsVerificationError) {
      throw new HttpError(400, "invalid_signature", `The ${what} signature is not valid.`);
    }
    throw error;
  }
}

/** Throws the contract's errors when a verified transaction is not for this app or this user. */
export function checkTransactionBelongsTo(
  transaction: JWSTransaction,
  userId: string,
  bundleId: string,
): void {
  if (transaction.bundleId !== bundleId) {
    throw new HttpError(403, "bundle_mismatch", "This purchase is for a different app.");
  }
  if (transaction.type !== undefined && transaction.type !== AUTO_RENEWABLE_TYPE) {
    throw new HttpError(400, "not_a_subscription", "This purchase is not a subscription.");
  }
  if (transaction.appAccountToken?.toLowerCase() !== userId.toLowerCase()) {
    throw new HttpError(
      403,
      "account_mismatch",
      "This subscription was bought while signed in to a different DayLedger account.",
    );
  }
}

interface LatestFromApi {
  status: SubscriptionStatus;
  transaction: JWSTransaction;
  renewal?: JWSRenewalInfo;
}

async function latestFromApi(
  response: SubscriptionStatusesResponse,
  originalTransactionId: string,
  deps: VerifyTransactionDeps,
): Promise<LatestFromApi | undefined> {
  for (const group of response.data ?? []) {
    for (const last of group.lastTransactions ?? []) {
      if (last.originalTransactionId !== originalTransactionId) continue;
      const transaction = await verifyOr400<JWSTransaction>(
        deps.verify,
        last.signedTransactionInfo,
        "App Store transaction",
      );
      const renewal = last.signedRenewalInfo
        ? await verifyOr400<JWSRenewalInfo>(deps.verify, last.signedRenewalInfo, "renewal info")
        : undefined;
      return {
        status: statusFromApiStatus(last.status, transaction, renewal, deps.now),
        transaction,
        renewal,
      };
    }
  }
  return undefined;
}

/**
 * Verifies a StoreKit 2 signed transaction for `userId` and returns the subscription state to
 * store. Uses the App Store Server API for the latest status when available, otherwise trusts
 * the verified transaction alone.
 */
export async function resolveSubscription(
  signedTransaction: unknown,
  userId: string,
  deps: VerifyTransactionDeps,
): Promise<SubscriptionState> {
  if (typeof signedTransaction !== "string" || signedTransaction.length === 0) {
    throw new HttpError(400, "invalid_request", "signedTransaction is required.");
  }
  const transaction = await verifyOr400<JWSTransaction>(
    deps.verify,
    signedTransaction,
    "transaction",
  );
  checkTransactionBelongsTo(transaction, userId, deps.config.bundleId);

  let status = statusFromTransaction(transaction, undefined, deps.now);
  let latest: JWSTransaction = transaction;
  let renewal: JWSRenewalInfo | undefined;

  if (deps.fetchStatuses) {
    try {
      const response = await deps.fetchStatuses(transaction.transactionId);
      const fromApi = await latestFromApi(response, transaction.originalTransactionId, deps);
      if (fromApi) {
        // The latest renewal must still be ours (same app, same account).
        checkTransactionBelongsTo(fromApi.transaction, userId, deps.config.bundleId);
        status = fromApi.status;
        latest = fromApi.transaction;
        renewal = fromApi.renewal;
      } else {
        deps.log?.("App Store Server API returned no status for this subscription");
      }
    } catch (error) {
      if (error instanceof HttpError) throw error;
      // Apple unreachable or misconfigured keys: the signed transaction is still authentic.
      deps.log?.("App Store Server API lookup failed; using the signed transaction", error);
    }
  }

  try {
    return buildSubscriptionState(status, latest, renewal);
  } catch (error) {
    if (error instanceof UnsupportedEnvironmentError) {
      throw new HttpError(400, "unsupported_environment", error.message);
    }
    throw error;
  }
}
