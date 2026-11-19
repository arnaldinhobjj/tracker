// Persistence for subscriptions and the notification log, behind an interface so the
// verification/notification logic can be unit-tested with an in-memory fake.

import type { SupabaseClient } from "./deps.ts";
import { stateToRow, type SubscriptionRow } from "./entitlement.ts";
import { STATUS_NEUTRAL_NOTIFICATION_TYPES, type SubscriptionState } from "./status.ts";

/** The original transaction already belongs to a different DayLedger account. */
export class SubscriptionConflictError extends Error {
  constructor() {
    super("This App Store subscription is linked to another DayLedger account");
    this.name = "SubscriptionConflictError";
  }
}

export interface NotificationLogEntry {
  notificationUuid: string;
  notificationType: string;
  subtype: string | null;
  originalTransactionId: string | null;
  signedDate: Date;
  payload: unknown;
}

export type NotificationLogState = "new" | "pending" | "processed";

export interface SubscriptionStore {
  getSubscription(userId: string): Promise<SubscriptionRow | null>;
  /** Insert or replace the user's row. Throws SubscriptionConflictError on a foreign otid. */
  upsertSubscription(userId: string, state: SubscriptionState): Promise<SubscriptionRow>;
  updateAutoRenew(userId: string, autoRenew: boolean): Promise<void>;
  userExists(userId: string): Promise<boolean>;
  findUserIdByOriginalTransactionId(originalTransactionId: string): Promise<string | null>;
  /** Records the notification if new; reports whether it was already fully processed. */
  beginNotification(entry: NotificationLogEntry): Promise<NotificationLogState>;
  /** True when a newer status-changing notification for the same subscription was applied. */
  hasNewerProcessedNotification(entry: NotificationLogEntry): Promise<boolean>;
  markNotificationProcessed(notificationUuid: string, userId: string | null): Promise<void>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string | null | undefined): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

function fail(context: string, error: { message: string; code?: string }): never {
  throw new Error(`${context}: ${error.code ?? ""} ${error.message}`);
}

/** SubscriptionStore backed by Postgres through the service-role client. */
export class SupabaseSubscriptionStore implements SubscriptionStore {
  constructor(private readonly db: SupabaseClient) {}

  async getSubscription(userId: string): Promise<SubscriptionRow | null> {
    const { data, error } = await this.db
      .from("subscriptions")
      .select("*")
      .eq("user_id", userId)
      .maybeSingle();
    if (error) fail("Reading subscription", error);
    return data as SubscriptionRow | null;
  }

  async upsertSubscription(userId: string, state: SubscriptionState): Promise<SubscriptionRow> {
    const { data, error } = await this.db
      .from("subscriptions")
      .upsert(stateToRow(userId, state), { onConflict: "user_id" })
      .select("*")
      .single();
    if (error) {
      if (error.code === "23505") throw new SubscriptionConflictError();
      fail("Saving subscription", error);
    }
    return data as SubscriptionRow;
  }

  async updateAutoRenew(userId: string, autoRenew: boolean): Promise<void> {
    const { error } = await this.db
      .from("subscriptions")
      .update({ auto_renew: autoRenew })
      .eq("user_id", userId);
    if (error) fail("Updating auto_renew", error);
  }

  async userExists(userId: string): Promise<boolean> {
    if (!isUuid(userId)) return false;
    const { data, error } = await this.db.auth.admin.getUserById(userId);
    if (error) {
      if (error.status === 404) return false;
      fail("Looking up user", error);
    }
    return Boolean(data?.user);
  }

  async findUserIdByOriginalTransactionId(originalTransactionId: string): Promise<string | null> {
    const { data, error } = await this.db
      .from("subscriptions")
      .select("user_id")
      .eq("original_transaction_id", originalTransactionId)
      .maybeSingle();
    if (error) fail("Finding subscription owner", error);
    return (data as { user_id: string } | null)?.user_id ?? null;
  }

  async beginNotification(entry: NotificationLogEntry): Promise<NotificationLogState> {
    const { data: existing, error: readError } = await this.db
      .from("app_store_notifications")
      .select("processed_at")
      .eq("notification_uuid", entry.notificationUuid)
      .maybeSingle();
    if (readError) fail("Reading notification log", readError);
    if (existing) {
      return (existing as { processed_at: string | null }).processed_at ? "processed" : "pending";
    }
    const { error } = await this.db.from("app_store_notifications").upsert({
      notification_uuid: entry.notificationUuid,
      notification_type: entry.notificationType,
      subtype: entry.subtype,
      original_transaction_id: entry.originalTransactionId,
      signed_date: entry.signedDate.toISOString(),
      payload: entry.payload,
    }, { onConflict: "notification_uuid", ignoreDuplicates: true });
    if (error) fail("Writing notification log", error);
    return "new";
  }

  async hasNewerProcessedNotification(entry: NotificationLogEntry): Promise<boolean> {
    if (!entry.originalTransactionId) return false;
    const neutral = `(${STATUS_NEUTRAL_NOTIFICATION_TYPES.map((t) => `"${t}"`).join(",")})`;
    const { data, error } = await this.db
      .from("app_store_notifications")
      .select("notification_uuid")
      .eq("original_transaction_id", entry.originalTransactionId)
      .gt("signed_date", entry.signedDate.toISOString())
      .not("processed_at", "is", null)
      .not("notification_type", "in", neutral)
      .neq("notification_uuid", entry.notificationUuid)
      .limit(1);
    if (error) fail("Checking notification order", error);
    return (data ?? []).length > 0;
  }

  async markNotificationProcessed(notificationUuid: string, userId: string | null): Promise<void> {
    const { error } = await this.db
      .from("app_store_notifications")
      .update({ processed_at: new Date().toISOString(), user_id: userId })
      .eq("notification_uuid", notificationUuid);
    if (error) fail("Updating notification log", error);
  }
}
