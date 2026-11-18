// Third-party dependencies, pinned to exact versions in one place.
// (No deno.lock is committed: Supabase's deploy bundler can lag behind the local Deno's
// lockfile format, so versions are pinned here instead.)
export * as x509 from "npm:@peculiar/x509@1.14.3";
export { createClient } from "npm:@supabase/supabase-js@2.119.0";
export type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.119.0";
