// Service-role client and caller authentication for Edge Functions.
// The service role bypasses RLS, so it is only ever used server-side, after the caller has been
// identified from their own access token.

import { createClient, type SupabaseClient, type User } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { bearerToken, HttpError } from "./http.ts";

let admin: SupabaseClient | undefined;

export function adminClient(): SupabaseClient {
  admin ??= createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return admin;
}

/**
 * Resolves the signed-in user from the request's access token. The gateway already checked the
 * JWT (verify_jwt = true); asking Auth again also rejects tokens of users deleted since then.
 */
export async function requireUser(req: Request): Promise<User> {
  const token = bearerToken(req);
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data?.user) {
    throw new HttpError(401, "unauthorized", "Sign in again to continue.");
  }
  return data.user;
}
