// Core of POST app-store-notifications (App Store Server Notifications V2), free of HTTP code.

import type { JWSRenewalInfo, JWSTransaction, NotificationPayload } from "./apple_types.ts";
import type { AppleConfig } from "./env.ts";
import { HttpError } from "./http.ts";
import { JwsVerificationError, type JwsVerifier } from "./jws.ts";
import {
  autoRenewFrom,
  buildSubscriptionState,
  notificationEffect,
  UnsupportedEnvironmentError,
} from "./status.ts";
import {
  isUuid,
  type NotificationLogEntry,
  SubscriptionConflictError,
  type SubscriptionStore,
} from "./subscription_store.ts";

export type NotificationResult =
  | "applied"
  | "auto_renew_updated"
  | "duplicate"
  | "no_change"
  | "stale"
  | "unknown_user"
  | "other_app"
  | "conflict";

export interface NotificationDeps {
  config: AppleConfig;
  verify: JwsVerifier;
  store: SubscriptionStore;
  now: Date;
  log?: (message: string, error?: unknown) => void;
}

async function verifyOr400<T>(verify: JwsVerifier, jws: string): Promise<T> {
  try {
    return await verify<T>(jws);
  } catch (error) {
    if (error instanceof JwsVerificationError) {
      throw new HttpError(400, "invalid_signature", "The notification signature is not valid.");
    }
    throw error;
  }
}

/**
 * Verifies, logs (idempotently, by notificationUUID) and applies one notification.
 * Throws HttpError(400) only for unverifiable input; every verified notification resolves with
 * a result (and the handler answers 200 so Apple stops retrying), including unknown users.
 */
export async function processNotification(
  signedPayload: unknown,
  deps: NotificationDeps,
): Promise<NotificationResult> {
  if (typeof signedPayload !== "string" || signedPayload.length === 0) {
    throw new HttpError(400, "invalid_request", "signedPayload is required.");
  }
  const payload = await verifyOr400<NotificationPayload>(deps.verify, signedPayload);
  if (!payload.notificationUUID || !payload.notificationType || !payload.signedDate) {
    throw new HttpError(400, "invalid_request", "The notification payload is incomplete.");
  }

  const data = payload.data;
  if (data?.bundleId !== undefined && data.bundleId !== deps.config.bundleId) {
    deps.log?.(`Ignoring notification for another app (${data.bundleId})`);
    return "other_app";
  }
  if (
    deps.config.appAppleId !== undefined && data?.environment === "Production" &&
    data.appAppleId !== undefined && data.appAppleId !== deps.config.appAppleId
  ) {
    deps.log?.(`Ignoring notification for another App Apple ID (${data.appAppleId})`);
    return "other_app";
  }

  const transaction = data?.signedTransactionInfo
    ? await verifyOr400<JWSTransaction>(deps.verify, data.signedTransactionInfo)
    : undefined;
  const renewal = data?.signedRenewalInfo
    ? await verifyOr400<JWSRenewalInfo>(deps.verify, data.signedRenewalInfo)
    : undefined;

  const entry: NotificationLogEntry = {
    notificationUuid: payload.notificationUUID,
    notificationType: payload.notificationType,
    subtype: payload.subtype ?? null,
    originalTransactionId: transaction?.originalTransactionId ??
      renewal?.originalTransactionId ?? null,
    signedDate: new Date(payload.signedDate),
    // The decoded (verified) content, not the raw JWS strings.
    payload: {
      ...payload,
      data: data
        ? { ...data, signedTransactionInfo: undefined, signedRenewalInfo: undefined }
        : undefined,
      transaction,
      renewal,
    },
  };

  const logState = await deps.store.beginNotification(entry);
  if (logState === "processed") return "duplicate";

  const finish = async (result: NotificationResult, userId: string | null = null) => {
    await deps.store.markNotificationProcessed(entry.notificationUuid, userId);
    return result;
  };

  const effect = notificationEffect(
    payload.notificationType,
    payload.subtype,
    transaction,
    renewal,
    deps.now,
  );
  if (effect.kind === "none" || !transaction) return await finish("no_change");

  // Find the account: appAccountToken (= user id) first, then the stored original transaction.
  const token = transaction.appAccountToken?.toLowerCase();
  let userId: string | null = null;
  if (isUuid(token) && await deps.store.userExists(token)) {
    userId = token;
  } else {
    userId = await deps.store.findUserIdByOriginalTransactionId(
      transaction.originalTransactionId,
    );
  }
  if (!userId) return await finish("unknown_user");

  if (effect.kind === "status" && await deps.store.hasNewerProcessedNotification(entry)) {
    return await finish("stale", userId);
  }

  const existing = await deps.store.getSubscription(userId);
  if (effect.kind === "auto_renew") {
    if (!existing) return await finish("no_change", userId);
    const fallback = payload.subtype === "AUTO_RENEW_ENABLED"
      ? true
      : payload.subtype === "AUTO_RENEW_DISABLED"
      ? false
      : existing.auto_renew;
    await deps.store.updateAutoRenew(userId, autoRenewFrom(renewal, fallback));
    return await finish("auto_renew_updated", userId);
  }

  try {
    const state = buildSubscriptionState(
      effect.status,
      transaction,
      renewal,
      existing?.auto_renew ?? true,
    );
    await deps.store.upsertSubscription(userId, state);
  } catch (error) {
    if (error instanceof UnsupportedEnvironmentError) {
      deps.log?.(error.message);
      return await finish("no_change", userId);
    }
    if (error instanceof SubscriptionConflictError) {
      deps.log?.(
        `Original transaction ${transaction.originalTransactionId} belongs to another user`,
      );
      return await finish("conflict", userId);
    }
    throw error;
  }
  return await finish("applied", userId);
}
