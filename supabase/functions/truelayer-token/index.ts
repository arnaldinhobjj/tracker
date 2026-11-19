// POST /functions/v1/truelayer-token  (anon key or a user JWT; checked by the gateway)
// Body: {"grant_type": "authorization_code", "code": "..."}
//    or {"grant_type": "refresh_token", "refresh_token": "..."}
// Exchanges or refreshes TrueLayer tokens with the client secret, which lives only in this
// function's secrets. No DayLedger account is needed: bank connections work without one.
// Tokens are passed through and never stored or logged.
// App Attest (APP_ATTEST_MODE): requests carry an assertion over the body from a genuine install.

import {
  appAttestConfigFromEnv,
  type AttestOutcome,
  checkRequestAttestation,
  withAttestStatus,
} from "../_shared/app_attest.ts";
import { SupabaseAppAttestStore } from "../_shared/app_attest_store.ts";
import { handler, json, readJsonObjectWithRaw } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { exchangeToken, parseGrant, trueLayerConfigFromEnv } from "../_shared/truelayer.ts";

Deno.serve(handler(["POST"], async (req) => {
  const { body, raw } = await readJsonObjectWithRaw(req);
  const attest = appAttestConfigFromEnv();
  let outcome: AttestOutcome = "disabled";
  if (attest.mode !== "off") {
    outcome = await checkRequestAttestation(
      req,
      raw,
      attest,
      new SupabaseAppAttestStore(adminClient()),
    );
  }
  const grant = parseGrant(body);
  const result = await exchangeToken(grant, trueLayerConfigFromEnv());
  const response = json(result.body, result.status);
  response.headers.set("Cache-Control", "no-store");
  return withAttestStatus(response, outcome);
}));
