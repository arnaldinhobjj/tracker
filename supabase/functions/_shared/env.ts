// Environment / secrets access. Nothing secret is ever hard-coded in the repo.

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}

export function optionalEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value ? value : undefined;
}

export interface AppStoreApiCredentials {
  issuerId: string;
  keyId: string;
  /** Contents of the App Store Connect .p8 key (PKCS#8 PEM). */
  privateKey: string;
  bundleId: string;
}

export interface AppleConfig {
  bundleId: string;
  /** Numeric App Apple ID; only present once the app exists in App Store Connect. */
  appAppleId?: number;
  /** Present only when all App Store Server API secrets are configured. */
  api?: AppStoreApiCredentials;
}

export function appleConfigFromEnv(): AppleConfig {
  const bundleId = requireEnv("APPLE_BUNDLE_ID");
  const appAppleIdRaw = optionalEnv("APPLE_APP_APPLE_ID");
  const appAppleId = appAppleIdRaw ? Number(appAppleIdRaw) : undefined;
  if (appAppleId !== undefined && !Number.isSafeInteger(appAppleId)) {
    throw new Error("APPLE_APP_APPLE_ID must be the numeric App Apple ID");
  }
  const issuerId = optionalEnv("APPLE_ISSUER_ID");
  const keyId = optionalEnv("APPLE_KEY_ID");
  const privateKey = optionalEnv("APPLE_PRIVATE_KEY");
  const api = issuerId && keyId && privateKey
    ? { issuerId, keyId, privateKey, bundleId }
    : undefined;
  return { bundleId, appAppleId, api };
}
