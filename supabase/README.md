# DayLedger backend (Supabase)

Postgres schema + row-level security, Supabase Auth, four Edge Functions that verify the
App Store subscription, one that exchanges TrueLayer tokens so the client secret never ships
in the app, and one that runs AI suggestions for DayLedger Pro with DayLedger's own Anthropic key. Synced transactions and visits are end-to-end encrypted by the app: the database
stores ciphertext. The binding spec is [`docs/backend-contract.md`](../docs/backend-contract.md).

```
supabase/
  config.toml                         local stack (`supabase start`) + function JWT settings
  migrations/                         schema, RLS, has_active_entitlement(), grants
  tests/database/*.test.sql           pgTAP: RLS isolation, entitlement gating, cascade deletes, encryption, recovery key, AI quota, App Attest
  functions/
    verify-subscription/              POST, user JWT: verify a StoreKit 2 transaction, store it
    entitlement/                      GET,  user JWT: current entitlement
    app-store-notifications/          POST, no JWT: App Store Server Notifications V2
    delete-account/                   POST, user JWT: delete the auth user (cascades)
    truelayer-token/                  POST, anon key: TrueLayer code exchange / refresh with the client secret
    ai-suggest/                       POST, user JWT + Pro: AI event suggestions (Anthropic), daily limit
    app-attest/                       POST, anon key: register an App Attest key (challenge, attestation)
    _shared/                          JWS verification, App Store Server API, status mapping, …
```

Nothing secret lives in this repo. You need the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
(`brew install supabase/tap/supabase`) and, for local work, Docker and [Deno 2](https://deno.com).

## 1. Create the project

1. <https://supabase.com/dashboard> → **New project**. Region: **West EU (London)** (`eu-west-2`)
   or another EU region. Save the database password in your password manager.
2. From the repo root:

   ```sh
   supabase login
   supabase link --project-ref <ref>          # <ref> is in the project URL
   supabase db push                           # applies supabase/migrations
   supabase functions deploy                  # deploys all six functions
   ```

   `supabase functions deploy` reads `config.toml`, so `app-store-notifications` is deployed
   with JWT verification off (Apple calls it without a Supabase token) and the others with it on.
   `truelayer-token` keeps verification on: the app calls it with the anon key, which is a valid
   JWT for projects using the legacy anon key. (If your project only has the new
   `sb_publishable_…` keys, deploy it with `--no-verify-jwt`; the secret is still never exposed.)
   If you deploy one function by name, pass `--no-verify-jwt` for `app-store-notifications` only.

3. **Project Settings → API**: copy the project URL and the anon (publishable) key into the iOS
   app's `Config/Local.xcconfig` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). Never ship the
   service-role key in the app.

## 2. Function secrets

```sh
supabase secrets set \
  APPLE_BUNDLE_ID=<the app's bundle id> \
  APPLE_ISSUER_ID=<issuer id> \
  APPLE_KEY_ID=<key id> \
  APPLE_APP_APPLE_ID=<numeric app id> \
  APPLE_PRIVATE_KEY="$(cat SubscriptionKey_XXXXXXXXXX.p8)"

supabase secrets set \
  TRUELAYER_CLIENT_ID=<client id> \
  TRUELAYER_CLIENT_SECRET=<client secret> \
  TRUELAYER_ENVIRONMENT=sandbox            # or live, once TrueLayer approves production

supabase secrets set ANTHROPIC_API_KEY=<key from console.anthropic.com>
# Optional: ANTHROPIC_MODEL (default claude-opus-5-5), AI_DAILY_LIMIT (default 20 per user per day)

supabase secrets set APP_ATTEST_APP_ID=<Team ID>.<bundle id>   # e.g. ABCDE12345.app.dayledger
# Optional: APP_ATTEST_MODE (off | report | enforce; default report),
#           APP_ATTEST_ALLOW_DEVELOPMENT=true (accept keys from Xcode/development builds)
```

| Secret | Where it comes from |
|---|---|
| `APPLE_BUNDLE_ID` | Xcode target → General → Bundle Identifier (also App Store Connect → App Information). Required. |
| `APPLE_ISSUER_ID` | App Store Connect → Users and Access → Integrations → **In-App Purchase** keys → Issuer ID (top of the page). |
| `APPLE_KEY_ID` | Same page → **Generate In-App Purchase Key** → the key's ID. |
| `APPLE_PRIVATE_KEY` | The `.p8` file downloaded when you created that key (one download only). Paste the whole file, including the BEGIN/END lines. |
| `APPLE_APP_APPLE_ID` | App Store Connect → your app → App Information → **Apple ID** (a number). Production notifications for another app id are ignored. |
| `TRUELAYER_CLIENT_ID` | TrueLayer console → App settings. Must equal the app's `TRUELAYER_CLIENT_ID`. Required by `truelayer-token`. |
| `TRUELAYER_CLIENT_SECRET` | TrueLayer console → App settings. Lives only here; never in the app or the repo. Required by `truelayer-token`. |
| `TRUELAYER_ENVIRONMENT` | `sandbox` (default) or `live`. |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API keys. Required by `ai-suggest`. Billed to DayLedger's Anthropic account; `AI_DAILY_LIMIT` caps each user. |
| `APP_ATTEST_APP_ID` | `<Team ID>.<bundle id>`: Apple Developer → Membership → Team ID, plus the app's bundle ID. Without it App Attest is off. |
| `APP_ATTEST_MODE` | `report` (default): check and log, never refuse. `enforce`: `truelayer-token` and `ai-suggest` refuse requests without a valid App Attest signature (simulators and app versions before App Attest stop working against that backend). `off`: don't check. |
| `APP_ATTEST_ALLOW_DEVELOPMENT` | `true` to accept keys from development-signed builds (Xcode installs). Leave unset in production. |
| `TRUELAYER_REDIRECT_URI` | Optional; default `dayledger://truelayer-callback`. Must match the app and the TrueLayer console. |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.
Without the three API secrets (`ISSUER_ID`, `KEY_ID`, `PRIVATE_KEY`) `verify-subscription`
still works but trusts the signed transaction from the device alone instead of asking Apple for
the latest status; set them before launch.

## 3. Auth

**Authentication → URL Configuration**

- Site URL: `dayledger://auth-callback`
- Redirect URLs: add `dayledger://auth-callback`

**Authentication → Providers → Email**: enabled, **Confirm email** on, minimum password length 8.

**Sign in with Apple** (Authentication → Providers → Apple → enable)

- **Client IDs**: the app's bundle id. This is what native sign-in (`grant_type=id_token`) needs.
  Add a Services ID too only if you ever add web sign-in.
- Secret key: leave empty for native-only sign-in (it is only used by the web OAuth flow).
- In the Apple Developer portal the App ID needs the *Sign in with Apple* capability.

**Google** (Authentication → Providers → Google → enable)

1. Google Cloud Console → APIs & Services → Credentials → **Create OAuth client ID** →
   type **Web application**.
2. Authorized redirect URI: `https://<ref>.supabase.co/auth/v1/callback`
3. Paste the web **Client ID** and **Client secret** into Supabase. The app reaches Google
   through Supabase (`/auth/v1/authorize` + PKCE), so no iOS client id is needed.

## 4. App Store Connect

**Subscription product**

1. Your app → Monetization → **Subscriptions** → create group **DayLedger Pro**.
2. Add an auto-renewable subscription: Reference name *DayLedger Pro Monthly*, Product ID
   **`app.dayledger.pro.monthly`**, duration **1 month**, price **£4.99** (UK storefront; let
   Apple derive the other storefronts).
3. Subscription Prices → **Introductory Offer** → **Free**, **1 week** (the 7-day free trial),
   all storefronts. Apple enforces one trial per Apple ID per group.
4. Add localization and the review screenshot, then submit it with the app version.

**App Store Server Notifications V2** (your app → App Information → App Store Server
Notifications)

- Production Server URL: `https://<ref>.supabase.co/functions/v1/app-store-notifications`
- Sandbox Server URL: the same URL
- Version: **Version 2**

Then use **Request a Test Notification** (or the App Store Server API) and check the function
logs: a `TEST` notification is answered `200 {"received":true,"result":"no_change"}`.

## 5. Local development

```sh
supabase start                     # Postgres, Auth, REST, Edge Runtime (needs Docker)
supabase test db                   # pgTAP tests in supabase/tests/database
supabase db advisors               # security/performance advisors

cd supabase/functions
deno fmt --check && deno lint && deno check '**/*.ts'
deno test --allow-read --allow-env # unit tests (status mapping, entitlement, JWS, API client)

# Run the functions against the local stack; put local values in supabase/functions/.env
# (gitignored), e.g. APPLE_BUNDLE_ID=...
supabase functions serve --env-file supabase/functions/.env
```

For local Sign in with Apple / Google, export `SUPABASE_AUTH_EXTERNAL_APPLE_CLIENT_ID`,
`SUPABASE_AUTH_EXTERNAL_APPLE_SECRET`, `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and
`SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` (or put them in `supabase/.env`) before `supabase start`.

Purchases made with Xcode's local StoreKit configuration are signed by a local Xcode
certificate, not Apple's root, so `verify-subscription` rejects them (`400 invalid_signature`).
Test the server path with a Sandbox account on a device or TestFlight.

CI (`.github/workflows/backend.yml`) runs the Deno checks and the pgTAP suite on every change
under `supabase/`.

## Notes

- **Trust anchor**: `functions/_shared/apple_root_ca.ts` bundles Apple Root CA - G3 and pins its
  SHA-256 fingerprint; every JWS must chain leaf → Apple WWDR intermediate → that root, with
  valid dates and an ES256 signature. Its header comment explains how to re-check the bytes.
- **Gating**: reading needs sign-in; inserts/updates on `transactions`, `visits` and
  `user_settings` need `has_active_entitlement()`. Deletes are always allowed. Soft-deleting
  (`deleted_at`) is an update, so a lapsed user's app must hard-`DELETE` instead.
- **Account deletion** removes the auth user and, by cascade, every row including the
  subscription record. The App Store subscription itself keeps running until the user cancels
  it in Settings; a new account cannot claim it because its `appAccountToken` is the old id.
