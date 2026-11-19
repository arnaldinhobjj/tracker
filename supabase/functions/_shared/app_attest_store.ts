// App Attest keys and challenges in Postgres (service role; see the app_attest migration).

import type { SupabaseClient } from "./deps.ts";
import type { AppAttestRegistry, RegisteredKey } from "./app_attest.ts";

export class SupabaseAppAttestStore implements AppAttestRegistry {
  constructor(private readonly db: SupabaseClient) {}

  async getKey(keyId: string): Promise<{ publicKey: string; counter: number } | null> {
    const { data, error } = await this.db
      .from("app_attest_keys")
      .select("public_key, sign_count")
      .eq("key_id", keyId)
      .maybeSingle();
    if (error) throw error;
    return data ? { publicKey: data.public_key, counter: Number(data.sign_count) } : null;
  }

  async advanceCounter(keyId: string, counter: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("advance_app_attest_counter", {
      p_key_id: keyId,
      p_counter: counter,
    });
    if (error) throw error;
    return data === true;
  }

  async saveChallenge(challenge: string, expiresAt: Date): Promise<void> {
    const { error } = await this.db
      .from("app_attest_challenges")
      .insert({ challenge, expires_at: expiresAt.toISOString() });
    if (error) throw error;
  }

  async consumeChallenge(challenge: string): Promise<boolean> {
    const { data, error } = await this.db.rpc("consume_app_attest_challenge", {
      p_challenge: challenge,
    });
    if (error) throw error;
    return data === true;
  }

  async saveKey(key: RegisteredKey): Promise<void> {
    // A key ID is the hash of a fresh Secure Enclave key, so it can't already exist; if a retried
    // registration repeats it, the first row (and its counter) stays.
    const { error } = await this.db.from("app_attest_keys").upsert({
      key_id: key.keyId,
      public_key: key.publicKey,
      sign_count: key.counter,
      environment: key.environment,
    }, { onConflict: "key_id", ignoreDuplicates: true });
    if (error) throw error;
  }
}
