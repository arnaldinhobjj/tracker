// GET /functions/v1/entitlement  (requires the user's JWT)
// Returns the caller's entitlement from their subscriptions row
// ({"active":false,"status":"none",...} when there is none).

import { entitlementFromRow } from "../_shared/entitlement.ts";
import { handler, json } from "../_shared/http.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";
import { SupabaseSubscriptionStore } from "../_shared/subscription_store.ts";

Deno.serve(handler(["GET"], async (req) => {
  const user = await requireUser(req);
  const row = await new SupabaseSubscriptionStore(adminClient()).getSubscription(user.id);
  return json(entitlementFromRow(row, new Date()));
}));
