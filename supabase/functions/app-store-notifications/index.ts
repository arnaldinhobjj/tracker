// POST /functions/v1/app-store-notifications  (no JWT: called by Apple; verify_jwt = false)
// App Store Server Notifications V2. Body: {"signedPayload": "<JWS>"}.
// 400 when the signature does not verify; 200 for every verified notification (also duplicates
// and unknown users) so Apple stops retrying; 500 only if storing it failed (Apple retries).

import { appleConfigFromEnv } from "../_shared/env.ts";
import { handler, json, readJsonObject } from "../_shared/http.ts";
import { defaultVerifier } from "../_shared/jws.ts";
import { processNotification } from "../_shared/notifications.ts";
import { adminClient } from "../_shared/supabase.ts";
import { SupabaseSubscriptionStore } from "../_shared/subscription_store.ts";

Deno.serve(handler(["POST"], async (req) => {
  const body = await readJsonObject(req);
  const result = await processNotification(body.signedPayload, {
    config: appleConfigFromEnv(),
    verify: defaultVerifier,
    store: new SupabaseSubscriptionStore(adminClient()),
    now: new Date(),
    log: (message, error) => console.warn(message, error ?? ""),
  });
  return json({ received: true, result });
}));
