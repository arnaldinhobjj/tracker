// In-memory SubscriptionStore for unit tests.

import { stateToRow, type SubscriptionRow } from "../entitlement.ts";
import { STATUS_NEUTRAL_NOTIFICATION_TYPES, type SubscriptionState } from "../status.ts";
import {
  type NotificationLogEntry,
  type NotificationLogState,
  SubscriptionConflictError,
  type SubscriptionStore,
} from "../subscription_store.ts";

interface LoggedNotification extends NotificationLogEntry {
  processedAt: Date | null;
  userId: string | null;
}

export class MemoryStore implements SubscriptionStore {
  users = new Set<string>();
  subscriptions = new Map<string, SubscriptionRow>();
  notifications = new Map<string, LoggedNotification>();

  getSubscription(userId: string): Promise<SubscriptionRow | null> {
    return Promise.resolve(this.subscriptions.get(userId) ?? null);
  }

  upsertSubscription(userId: string, state: SubscriptionState): Promise<SubscriptionRow> {
    for (const [owner, row] of this.subscriptions) {
      if (owner !== userId && row.original_transaction_id === state.originalTransactionId) {
        return Promise.reject(new SubscriptionConflictError());
      }
    }
    const row = stateToRow(userId, state);
    this.subscriptions.set(userId, row);
    return Promise.resolve(row);
  }

  updateAutoRenew(userId: string, autoRenew: boolean): Promise<void> {
    const row = this.subscriptions.get(userId);
    if (row) row.auto_renew = autoRenew;
    return Promise.resolve();
  }

  userExists(userId: string): Promise<boolean> {
    return Promise.resolve(this.users.has(userId));
  }

  findUserIdByOriginalTransactionId(otid: string): Promise<string | null> {
    for (const [owner, row] of this.subscriptions) {
      if (row.original_transaction_id === otid) return Promise.resolve(owner);
    }
    return Promise.resolve(null);
  }

  beginNotification(entry: NotificationLogEntry): Promise<NotificationLogState> {
    const existing = this.notifications.get(entry.notificationUuid);
    if (existing) return Promise.resolve(existing.processedAt ? "processed" : "pending");
    this.notifications.set(entry.notificationUuid, { ...entry, processedAt: null, userId: null });
    return Promise.resolve("new");
  }

  hasNewerProcessedNotification(entry: NotificationLogEntry): Promise<boolean> {
    for (const n of this.notifications.values()) {
      if (
        n.notificationUuid !== entry.notificationUuid &&
        n.originalTransactionId === entry.originalTransactionId &&
        n.processedAt !== null &&
        n.signedDate > entry.signedDate &&
        !STATUS_NEUTRAL_NOTIFICATION_TYPES.includes(n.notificationType)
      ) {
        return Promise.resolve(true);
      }
    }
    return Promise.resolve(false);
  }

  markNotificationProcessed(notificationUuid: string, userId: string | null): Promise<void> {
    const n = this.notifications.get(notificationUuid);
    if (n) {
      n.processedAt = new Date();
      n.userId = userId;
    }
    return Promise.resolve();
  }
}
