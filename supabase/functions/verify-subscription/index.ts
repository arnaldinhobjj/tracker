// POST /functions/v1/verify-subscription  (requires the user's JWT)
// Body: {"signedTransaction": "<StoreKit 2 Transaction.jwsRepresentation>"}
// Verifies the purchase, stores the subscription and returns the entitlement.

import { getAllSubscriptionStatuses } from "../_shared/app_store_api.ts";
import { entitlementFromRow } from "../_shared/entitlement.ts";
import { appleConfigFromEnv } from "../_shared/env.ts";
import { handler, HttpError, json, readJsonObject } from "../_shared/http.ts";
import { defaultVerifier } from "../_shared/jws.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";
import {
  SubscriptionConflictError,
  SupabaseSubscriptionStore,
} from "../_shared/subscription_store.ts";
import { resolveSubscription } from "../_shared/verify_transaction.ts";

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = await readJsonObject(req);
  const config = appleConfigFromEnv();
  const api = config.api;
  const now = new Date();

  const state = await resolveSubscription(body.signedTransaction, user.id, {
    config,
    verify: defaultVerifier,
    fetchStatuses: api
      ? (transactionId) => getAllSubscriptionStatuses(transactionId, api)
      : undefined,
    now,
    log: (message, error) => console.warn(message, error ?? ""),
  });

  const store = new SupabaseSubscriptionStore(adminClient());
  try {
    const row = await store.upsertSubscription(user.id, state);
    return json(entitlementFromRow(row, now));
  } catch (error) {
    if (error instanceof SubscriptionConflictError) {
      throw new HttpError(409, "subscription_in_use", error.message);
    }
    throw error;
  }
}));
