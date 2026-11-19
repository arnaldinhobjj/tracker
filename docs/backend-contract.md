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
- **Cloud data:** everything the app stores (transactions, visits, settings) syncs to the
  user's account. Protected by TLS, Supabase at-rest encryption and row-level security (each
  user only ever sees their own rows). **Bank, Google and AI tokens/keys never leave the
  device** (Keychain only) and have no table.
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
| column | type | notes |
|---|---|---|
| id | text | app's transaction id (`<accountID>:<bankTxID>`) |
| account_id | text | |
| merchant | text | |
| raw_description | text | |
| amount_minor | bigint | pence, always positive |
| currency | char(3) | e.g. `GBP` |
| direction | text | check in (`debit`, `credit`) |
| bank_category | text | |
| category | text | SpendCategory raw value (`groceries`, `eatingOut`, `coffee`, `transport`, `shopping`, `bills`, `entertainment`, `health`, `travel`, `cash`, `transfer`, `income`, `other`) — no check constraint, so new categories don't need a migration |
| occurred_at | timestamptz | |
| has_time | boolean | |
| is_pending | boolean | |
| updated_at | timestamptz | trigger-set |
| deleted_at | timestamptz null | soft delete |

Index: `(user_id, updated_at)`, `(user_id, occurred_at desc)`.

### `visits` — pk `(user_id, id)`
| column | type |
|---|---|
| id | text (UUID string from the app) |
| arrival | timestamptz |
| departure | timestamptz null |
| latitude, longitude | double precision |
| place_name, place_category | text null |
| is_named_place, is_resolved | boolean |
| calendar_event_id, calendar_content_hash | text null |
| calendar_synced_at | timestamptz null |
| updated_at | timestamptz (trigger) |
| deleted_at | timestamptz null |

Index: `(user_id, updated_at)`.

### `user_settings` — pk `user_id`
| column | type | notes |
|---|---|---|
| settings | jsonb | `{"locationLogging":bool,"calendarWriting":bool,"onlyNamedPlaces":bool,"minimumVisitMinutes":int,"aiAssistant":bool}` |
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

### Function secrets
`APPLE_BUNDLE_ID`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (App Store Connect
API key, .p8 contents), `APPLE_APP_APPLE_ID` (numeric, production only). Supabase provides
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`. None of these are in the repo.

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
- Order: pull first, then push.
- Conflict rule: last write wins by server `updated_at`.

## iOS configuration

`Config/Local.xcconfig` (gitignored): `SUPABASE_URL` (write `https:/$()/xyz.supabase.co`,
because `//` starts an xcconfig comment) and `SUPABASE_ANON_KEY` (public by design; RLS protects
data). Exposed in Info.plist as `DLSupabaseURL` and `DLSupabaseAnonKey`.
Launch argument `-UITestMockData` skips login and paywall (UI tests and the no-credentials demo).
