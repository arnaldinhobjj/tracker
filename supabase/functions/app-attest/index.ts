// POST /functions/v1/app-attest  (anon key or a user JWT; checked by the gateway)
// Body: {"action": "challenge"}  ->  {"challenge": "..."}  (one use, valid for 5 minutes)
//    or {"action": "register", "keyId": "...", "attestation": "<base64>", "challenge": "..."}
//        ->  {"registered": true}
// Registers an App Attest key of a genuine DayLedger install (see _shared/app_attest.ts).
// Stores only the key's public half and its counter; nothing about the user.

import { appAttestConfigFromEnv, handleAppAttest } from "../_shared/app_attest.ts";
import { SupabaseAppAttestStore } from "../_shared/app_attest_store.ts";
import { handler, json, readJsonObject } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

Deno.serve(handler(["POST"], async (req) => {
  const body = await readJsonObject(req);
  const result = await handleAppAttest(
    body,
    appAttestConfigFromEnv(),
    new SupabaseAppAttestStore(adminClient()),
  );
  const response = json(result);
  response.headers.set("Cache-Control", "no-store");
  return response;
}));
