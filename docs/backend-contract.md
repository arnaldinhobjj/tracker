# DayLedger backend contract

The single source of truth shared by the Supabase backend (`supabase/`) and the iOS app.
Change it here first, then on both sides.

## Decisions

- **Backend:** Supabase (Postgres, Auth, Edge Functions). EU or UK region recommended.
- **Login:** email + password, Sign in with Apple, Google — all via Supabase Auth (GoTrue).
- **Payments:** App Store auto-renewable subscription, verified by our own Edge Functions
  (App Store Server API + App Store Server Notifications V2). No RevenueCat, no Stripe.
- **Product:** `app.dayledger.pro.monthly`, group "DayLedger Pro", £4.99/month,
  introductory offer: 7-day free trial (one per Apple ID, managed by Apple).
- **Local-first:** the app works without an account (Today, widgets, bank connections, Places,
  calendar diary). An account and DayLedger Pro unlock cloud sync and AI suggestions.
- **Cloud data:** transactions sync to the user's account; visits only when the user turns on
  visit sync (account-wide setting, off by default); settings always. Transactions and visits are
  **end-to-end encrypted** on the device (see "Encryption"): the server stores ciphertext only.
  Also protected by TLS, Supabase at-rest encryption and row-level security. **Bank, Google and
  AI tokens/keys never leave the device** (Keychain only) and have no table.
- **TrueLayer client secret:** lives only in the `truelayer-token` function's secrets. Release
  builds of the app never contain it.
- **Gating:** reading your own data needs a signed-in account; *writing* synced data needs an
  active entitlement (trial, active or grace period). Lapsed users can still read and delete.

## Database (schema `public`)

All user tables have `user_id uuid not null references auth.users(id) on delete cascade`,
RLS enabled, and policies using `(select auth.uid()) = user_id`. `updated_at` is always set by
a `before insert or update` trigger to `now()` (clients never set it; it is the sync cursor).
Deletes from the app are soft (`deleted_at`), so other devices learn about them.

### `profiles`
| column | type | notes |
|---|---|---|
| id | uuid pk | = auth.users.id, cascade |
| email | text | copied from auth.users |
| display_name | text null | |
| created_at, updated_at | timestamptz | |

Created by an `after insert on auth.users` trigger (security definer, `search_path = ''`).
Client: select/update own row.

### `transactions` — pk `(user_id, id)`

Current app versions write `id`, `key_id`, `payload` and `deleted_at`, and send every other
column as an explicit null. The plaintext columns are only filled by app versions from before
end-to-end encryption ("legacy rows"); see "Encryption".

| column | type | notes |
|---|---|---|
| id | text | app's transaction id (`<accountID>:<bankTxID>`) |
| key_id | text null | fingerprint of the sealing key, 32 lowercase hex; set iff `payload` is |
| payload | text null | sealed content, `v1.<base64 AES-GCM combined>`, ≤ 16 KiB |
| account_id | text null | legacy only |
| merchant | text null | legacy only |
| raw_description | text null | legacy only |
| amount_minor | bigint null | legacy only; pence, always positive |
| currency | char(3) null | legacy only; e.g. `GBP` |
| direction | text null | legacy only; check in (`debit`, `credit`) |
| bank_category | text null | legacy only |
| category | text null | legacy only; SpendCategory raw value (`groceries`, `eatingOut`, `coffee`, `transport`, `shopping`, `bills`, `entertainment`, `health`, `travel`, `cash`, `transfer`, `income`, `other`) — no check constraint, so new categories don't need a migration |
| occurred_at | timestamptz null | legacy only |
| has_time | boolean null | legacy only |
| is_pending | boolean null | legacy only |
| updated_at | timestamptz | trigger-set |
| deleted_at | timestamptz null | soft delete |

Index: `(user_id, updated_at)`, `(user_id, occurred_at desc)` (the latter only covers legacy rows).
Constraints: a row is either encrypted (`payload` + `key_id`, every plaintext column null) or a
complete legacy row.

### `visits` — pk `(user_id, id)`

Only written when visit sync is on. Same shape rules as `transactions`.

| column | type |
|---|---|
| id | text (UUID string from the app) |
| key_id, payload | text null (encrypted rows) |
| arrival | timestamptz null (legacy only) |
| departure | timestamptz null (legacy only) |
| latitude, longitude | double precision null (legacy only) |
| place_name, place_category | text null (legacy only) |
| is_named_place, is_resolved | boolean null (legacy only) |
| calendar_event_id, calendar_content_hash | text null (legacy only; never read) |
| calendar_synced_at | timestamptz null (legacy only; never read) |
| updated_at | timestamptz (trigger) |
| deleted_at | timestamptz null |

Index: `(user_id, updated_at)`.

### `sync_keys` — pk `user_id`
| column | type | notes |
|---|---|---|
| key_id | text | fingerprint of the account's sync key (the key itself never reaches the server) |
| created_at | timestamptz | |

Insert-once (`ON CONFLICT DO NOTHING`; no update policy) so two devices can't register
competing keys. Select/insert/delete own row; no entitlement needed. Deleting it (with the
user's transactions and visits) is how a user starts encryption over.

### `user_settings` — pk `user_id`
| column | type | notes |
|---|---|---|
| settings | jsonb | `{"locationLogging":bool,"calendarWriting":bool,"onlyNamedPlaces":bool,"minimumVisitMinutes":int,"aiAssistant":bool,"visitSync":bool}` — a missing `visitSync` (older app versions) means off |
| updated_at | timestamptz | trigger |

### `subscriptions` — pk `user_id`
| column | type | notes |
|---|---|---|
| original_transaction_id | text unique | |
| product_id | text | |
| status | text | check in (`trial`,`active`,`grace_period`,`billing_retry`,`expired`,`revoked`,`refunded`) |
| expires_at | timestamptz | for `grace_period`: the grace period expiry |
| is_trial | boolean | |
| auto_renew | boolean | |
| environment | text | `Sandbox` / `Production` |
| app_account_token | uuid null | = user id |
| latest_transaction_id | text | |
| updated_at | timestamptz | trigger |

Client: **select own row only**. All writes by Edge Functions with the service role.

### `app_store_notifications` — pk `notification_uuid`
Audit + idempotency log of every verified notification (`notification_type`, `subtype`,
`original_transaction_id`, `signed_date`, `received_at`, `payload jsonb`). No client access.

### `ai_usage` — pk `(user_id, day)`
| column | type | notes |
|---|---|---|
| day | date | UTC day |
| requests | integer | AI suggestion requests that day |

Service role only (RLS on, no policies, no client grants). Erased with the account (cascade).
`public.consume_ai_quota(p_user_id uuid, p_limit int) returns boolean` atomically counts one
request and returns true, or returns false (counting nothing) when the limit is reached. Execute
granted to `service_role` only.

### `public.has_active_entitlement() returns boolean`
`security definer`, stable, `search_path = ''`. True when the caller's `subscriptions` row
has status in (`trial`,`active`,`grace_period`) and `expires_at > now()`. Used by the insert/
update RLS policies on `transactions`, `visits`, `user_settings`, and callable by the app via
`POST /rest/v1/rpc/has_active_entitlement`.

## Edge Functions (`/functions/v1/...`)

All responses are JSON. Errors: `{"error": "<code>", "message": "<human text>"}` with a 4xx/5xx.

### `POST verify-subscription` (requires user JWT)
Request: `{"signedTransaction": "<JWS from StoreKit 2 Transaction.jwsRepresentation>"}`

1. Verify the JWS: `x5c` chain to Apple Root CA - G3 (bundled), ES256 signature.
2. Check `bundleId == APPLE_BUNDLE_ID` and `appAccountToken == auth user id`
   (the app always buys with `appAccountToken = user id`). Mismatch → 403 `account_mismatch`.
3. Ask the App Store Server API for the latest status of `originalTransactionId`
   (`GET /inApps/v1/subscriptions/{transactionId}`, production then sandbox on 404), when the
   API key secrets are configured; otherwise trust the verified transaction alone.
4. Upsert `subscriptions`; return the entitlement:

Response 200: `{"active":true,"status":"trial","expiresAt":"2026-11-25T10:00:00Z","isTrial":true,"productId":"app.dayledger.pro.monthly"}`

### `GET entitlement` (requires user JWT)
Returns the same entitlement shape from the caller's `subscriptions` row
(`{"active":false,"status":"none",...}` when there is none).

### `POST app-store-notifications` (no JWT; called by Apple)
Body: `{"signedPayload": "<JWS>"}` (App Store Server Notifications V2). Verify, dedupe by
`notificationUUID`, decode `signedTransactionInfo`/`signedRenewalInfo`, map to `status`, find
the user by `appAccountToken` (fallback: `original_transaction_id`), upsert. Always 200 once
verified and stored (also for unknown users, so Apple stops retrying); 400 on bad signature.

Status mapping: `SUBSCRIBED`/`DID_RENEW` → `active` (or `trial` when `offerType == 1`);
`DID_FAIL_TO_RENEW` + `GRACE_PERIOD` → `grace_period`, else `billing_retry`;
`EXPIRED`/`GRACE_PERIOD_EXPIRED` → `expired`; `REVOKE` → `revoked`; `REFUND` → `refunded`;
`DID_CHANGE_RENEWAL_STATUS` → update `auto_renew` only.

### `POST delete-account` (requires user JWT)
Deletes the auth user with the admin API (cascades to every table). 200 `{"deleted":true}`.
The app then wipes local data and signs out. (Apple requires in-app account deletion; the
App Store subscription itself must be cancelled by the user in Settings — the app says so.)

### `POST truelayer-token` (anon key or user JWT, checked by the gateway)
Exchanges or refreshes TrueLayer tokens with the client secret, which only this function has.
No DayLedger account needed (bank connections are free and local). Tokens pass through; they
are never stored or logged.

Request: `{"grant_type":"authorization_code","code":"..."}` or
`{"grant_type":"refresh_token","refresh_token":"..."}`.

- 200: `{"access_token","refresh_token","expires_in","token_type","scope"}` (only these fields).
- 4xx from TrueLayer: same status with TrueLayer's OAuth error, e.g. 400 `{"error":"invalid_grant"}`
  (the app asks the user to reconnect). TrueLayer's 401 (our client credentials rejected) is
  returned as 400 so the app never mistakes it for an expired DayLedger session.
- 400 `invalid_request` / `unsupported_grant_type` for a bad body; 502 `upstream_unavailable`
  when TrueLayer can't be reached or fails.

### `POST ai-suggest` (requires user JWT; DayLedger Pro)
Request: `{"summary": <RoutineSummary>}` (the anonymised summary the app shows in "Preview what
would be sent"; ≤ 32 KiB). The function keeps only the summary's known fields, with bounded sizes,
so it can't be used as a general prompt proxy; builds the prompt; and calls Anthropic with
`ANTHROPIC_API_KEY`. Nothing is stored except the per-day count.

- 200: `{"text": "<the model's JSON: {\"proposals\":[…]}>"}`. The app validates every proposal.
- 400 `invalid_summary`, 413 `summary_too_large`
- 403 `not_entitled` (no active subscription)
- 429 `daily_limit` (`AI_DAILY_LIMIT` requests per user per UTC day; the request is counted
  before calling Anthropic)
- 422 `refused` (the model declined), 502 `truncated` / `provider_invalid` / `provider_error`,
  503 `provider_busy` (Anthropic rate-limited, overloaded or unreachable; Anthropic's own 401/403
  never reach the app as such)

### Function secrets
`APPLE_BUNDLE_ID`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (App Store Connect
API key, .p8 contents), `APPLE_APP_APPLE_ID` (numeric, production only).
`ANTHROPIC_API_KEY` (required by `ai-suggest`), `ANTHROPIC_MODEL` (default `claude-opus-5-5`),
`AI_DAILY_LIMIT` (default 20).
`TRUELAYER_CLIENT_ID`, `TRUELAYER_CLIENT_SECRET`, `TRUELAYER_ENVIRONMENT` (`sandbox` or `live`,
default `sandbox`), `TRUELAYER_REDIRECT_URI` (default `dayledger://truelayer-callback`). The
client ID must match the app's `TRUELAYER_CLIENT_ID`. Supabase provides `SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`. None of these are in the repo.

## Auth (Supabase GoTrue REST, called directly from iOS with `URLSession`)

Headers on every call: `apikey: <anon key>`; authenticated calls add
`Authorization: Bearer <access_token>`.

| Flow | Call |
|---|---|
| Register (email) | `POST /auth/v1/signup` `{"email","password"}` (+ `redirect_to=dayledger://auth-callback` query). Returns a session, or no session if email confirmation is on. |
| Login (email) | `POST /auth/v1/token?grant_type=password` `{"email","password"}` |
| Forgot password | `POST /auth/v1/recover` `{"email"}` |
| Apple | Native `ASAuthorizationAppleIDProvider`, nonce = SHA256(raw) → `POST /auth/v1/token?grant_type=id_token` `{"provider":"apple","id_token","nonce":"<raw>"}` |
| Google | `ASWebAuthenticationSession` to `/auth/v1/authorize?provider=google&redirect_to=dayledger://auth-callback&code_challenge=<S256>&code_challenge_method=s256` → callback `?code=` → `POST /auth/v1/token?grant_type=pkce` `{"auth_code","code_verifier"}` |
| Email-link callback | `dayledger://auth-callback?code=...` → same `grant_type=pkce` exchange |
| Refresh | `POST /auth/v1/token?grant_type=refresh_token` `{"refresh_token"}` |
| Sign out | `POST /auth/v1/logout` |

Session (access token, refresh token, expiry, user id, email) is stored in the **Keychain**.

## Sync (PostgREST)

- Push: `POST /rest/v1/<table>?on_conflict=user_id,id` with
  `Prefer: resolution=merge-duplicates,return=minimal`, batches of ≤ 500, `user_id` set to the
  signed-in user (RLS rejects anything else).
- Pull: keyset paging on `(updated_at, id)` so rows sharing a timestamp are never skipped:
  `GET /rest/v1/<table>?select=*&or=(updated_at.gt."<ts>",and(updated_at.eq."<ts>",id.gt."<id>"))&order=updated_at.asc,id.asc&limit=500`,
  repeat until fewer than 500. Cursor `(ts, id)` per user and table stored on device.
- Local deletes push `deleted_at = now()` while entitled; without an entitlement (updates are
  refused) they hard-`DELETE` own rows instead. Pulled rows with `deleted_at` are removed locally.
- Order: settings, then the key (see "Encryption"), then pull, then push.
- Conflict rule: last write wins by server `updated_at`.
- Visits are only pushed while `visitSync` is on. Turning it off (or "Remove from account")
  hard-deletes all of the user's visit rows; local copies stay on the device.

## Encryption

- **Key:** one random 256-bit key per account, created by the first device that syncs and kept
  in iCloud Keychain (synchronizable item, service `app.dayledger.synckeys`, account
  `sync.key.<user id>.<key id>`), so the user's other devices receive it and Apple can't read it.
  Its fingerprint (`key_id`, first 16 bytes of SHA-256 over a label and the key, hex) is
  registered in `sync_keys`; the key never leaves the user's devices and iCloud Keychain.
- **Finding the key:** read `sync_keys`. Registered and on this device → use it. Registered but
  not on this device → wait (the app explains iCloud Keychain) and sync nothing. None registered
  → generate, save locally, register with `ON CONFLICT DO NOTHING`, read back; if another device
  won the race, discard ours and wait for theirs.
- **Rows:** AES-256-GCM over the row's JSON content (`TransactionSyncContent` /
  `VisitSyncContent`, dates as milliseconds since 1970). Associated data
  `dayledger.sync.v1|<table>|<user id>|<row id>` binds each payload to its row and user. Stored as
  `v1.` + base64(nonce ‖ ciphertext ‖ tag). Tombstones are encrypted too.
- **Upgrade from plaintext:** the first time a device syncs with a key (or when the account's key
  changes) it pulls from the start. Legacy plaintext rows are applied locally and marked dirty, so
  they are uploaded again encrypted, which nulls the plaintext columns. Legacy tombstones are
  re-sent as encrypted tombstones (or hard-deleted without an entitlement). Legacy *visits* wait
  for the user to choose: keep (visit sync on, re-uploaded encrypted) or remove from the account.
  Rows of lapsed users stay plaintext until they subscribe again (RLS blocks their writes).
- **Older app versions** keep writing plaintext. When one updates an encrypted row, a trigger
  drops the stale ciphertext, so the row becomes a legacy row and newer devices re-encrypt it.
- **Start over** (key lost everywhere): delete the user's `transactions`, `visits` and
  `sync_keys` rows, then sync, which creates a new key and uploads this device's data.

## iOS configuration

`Config/Local.xcconfig` (gitignored): `SUPABASE_URL` (write `https:/$()/xyz.supabase.co`,
because `//` starts an xcconfig comment) and `SUPABASE_ANON_KEY` (public by design; RLS protects
data). Exposed in Info.plist as `DLSupabaseURL` and `DLSupabaseAnonKey`.
Launch argument `-UITestMockData` runs without accounts, in memory, with a mock bank (UI tests
and the no-credentials demo). The app never requires signing in: sign-in and the paywall are
sheets opened from Settings or from a Pro feature.
