// POST /functions/v1/truelayer-token  (anon key or a user JWT; checked by the gateway)
// Body: {"grant_type": "authorization_code", "code": "..."}
//    or {"grant_type": "refresh_token", "refresh_token": "..."}
// Exchanges or refreshes TrueLayer tokens with the client secret, which lives only in this
// function's secrets. No DayLedger account is needed: bank connections work without one.
// Tokens are passed through and never stored or logged.

import { handler, json, readJsonObject } from "../_shared/http.ts";
import { exchangeToken, parseGrant, trueLayerConfigFromEnv } from "../_shared/truelayer.ts";

Deno.serve(handler(["POST"], async (req) => {
  const grant = parseGrant(await readJsonObject(req));
  const result = await exchangeToken(grant, trueLayerConfigFromEnv());
  const response = json(result.body, result.status);
  response.headers.set("Cache-Control", "no-store");
  return response;
}));
