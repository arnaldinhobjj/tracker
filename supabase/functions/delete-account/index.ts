// POST /functions/v1/delete-account  (requires the user's JWT)
// Deletes the caller's auth user. Every table references auth.users with on delete cascade, so
// this erases profiles, transactions, visits, settings, the subscription row and their
// notification log entries. The App Store subscription itself must be cancelled by the user in
// Settings (the app tells them so).

import { handler, HttpError, json } from "../_shared/http.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const { error } = await adminClient().auth.admin.deleteUser(user.id);
  if (error) {
    console.error("Deleting user failed", error);
    throw new HttpError(500, "delete_failed", "Your account could not be deleted. Try again.");
  }
  return json({ deleted: true });
}));
