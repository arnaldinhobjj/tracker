// POST /functions/v1/ai-suggest  (requires the user's JWT; DayLedger Pro only)
// Body: {"summary": <the app's anonymised RoutineSummary>}
// Returns {"text": "<the model's JSON proposals>"}; the app validates every proposal itself.
// Uses DayLedger's Anthropic key (ANTHROPIC_API_KEY), limited per user per day (AI_DAILY_LIMIT).
// Nothing is stored except the per-day request count.

import { aiConfigFromEnv, suggest } from "../_shared/ai.ts";
import { entitlementFromRow } from "../_shared/entitlement.ts";
import { handler, json, readJsonObject } from "../_shared/http.ts";
import { SupabaseSubscriptionStore } from "../_shared/subscription_store.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = await readJsonObject(req);
  const admin = adminClient();
  const text = await suggest(user.id, body, aiConfigFromEnv(), {
    isEntitled: async (userId) => {
      const row = await new SupabaseSubscriptionStore(admin).getSubscription(userId);
      return entitlementFromRow(row, new Date()).active;
    },
    consumeQuota: async (userId, limit) => {
      const { data, error } = await admin.rpc("consume_ai_quota", {
        p_user_id: userId,
        p_limit: limit,
      });
      if (error) throw error;
      return data === true;
    },
    fetch,
  });
  const response = json({ text });
  response.headers.set("Cache-Control", "no-store");
  return response;
}));
