# DayLedger

An iOS app (SwiftUI, iOS 17+) that combines your spending, the places you visit and your calendar:

- **Today**: total spent today and today's transactions from your UK bank (Open Banking via TrueLayer), cached offline.
- **Widgets**: home screen (small, medium) and lock screen (rectangular, inline, circular) widgets showing today's spend.
- **Places**: battery-friendly visit logging that writes entries like "At Costa Coffee · £3.40, 09:10–09:45" to a dedicated **DayLedger** calendar, in Apple Calendar (default, no sign-in) or Google Calendar.
- **Suggest** (optional, DayLedger Pro): an AI assistant that proposes events from your routine. Nothing is added until you approve it.
- **Account** (optional): sign in for **DayLedger Pro**, which adds cloud sync (end-to-end encrypted) and AI suggestions. Everything above except Suggest works without an account.

> "DayLedger" is a placeholder name.

---

## Contents

1. [Requirements](#requirements)
2. [Build and run](#build-and-run)
3. [Configuration](#configuration)
4. [TrueLayer sandbox setup](#truelayer-sandbox-setup)
5. [Google Cloud OAuth setup](#google-cloud-oauth-setup)
6. [App Group and signing](#app-group-and-signing)
7. [AI assistant](#ai-assistant)
8. [Architecture](#architecture)
9. [Privacy and security](#privacy-and-security)
10. [Tests and CI](#tests-and-ci)
11. [What can't be tested without real credentials or a device](#what-cant-be-tested-without-real-credentials-or-a-device)
12. [Known limitations](#known-limitations)

---

## Requirements

- macOS with Xcode 16 or later (CI uses the current `macos-15` GitHub runner image)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) **2.47.0** (the version CI pins; other versions write a slightly different project), only if you change `project.yml` or add/remove files
- An Apple Developer account to run on a device. A paid membership is recommended: App Groups (needed by the widget) and long-lived installs are not reliable with a free "Personal Team".
- A TrueLayer developer account (free sandbox)
- A Google Cloud project (free)

## Build and run

`DayLedger.xcodeproj` is committed, so you can open it directly. It contains no secrets: every ID comes from `Config/Local.xcconfig`.

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Edit `Config/Local.xcconfig` (see [Configuration](#configuration)), then:

```bash
open DayLedger.xcodeproj
```

Select the **DayLedger** scheme and run. Without any credentials the app still launches straight into Today (no sign-in is ever required): it asks you to connect a bank, and Settings explains what's missing.

To try the UI with fake data and no credentials, add `-UITestMockData` under *Scheme → Run → Arguments Passed On Launch*. This uses an in-memory store and a mock bank.

The project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). To change targets, settings or Info.plist keys, edit `project.yml` rather than the project in Xcode, then regenerate:

```bash
brew install xcodegen
```

```bash
xcodegen --version
```

```bash
xcodegen generate
```

CI pins XcodeGen 2.47.0. If `xcodegen --version` shows something else, either install that release from [its GitHub release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.47.0) or just push: the CI check compares against 2.47.0's output. You also need to regenerate after adding or removing source files. If you push without regenerating, the **Sync Xcode project** workflow (`.github/workflows/xcodeproj.yml`) regenerates and commits it for you. Set your Team ID in `Config/Local.xcconfig`, not in Xcode's Signing UI, so your team isn't written into the committed project.

## Configuration

All IDs live in `Config/Local.xcconfig`, which is **git-ignored**. `Config/Base.xcconfig` holds empty defaults and includes it. Values reach the app through `Info.plist` and are read by `App/Support/AppConfiguration.swift`.

| Setting | Example | Purpose |
|---|---|---|
| `DL_BUNDLE_ID` | `com.yourname.dayledger` | App bundle ID. The widget is `$(DL_BUNDLE_ID).widget`. |
| `DL_DEVELOPMENT_TEAM` | `ABCDE12345` | Your Apple Team ID (Xcode → Settings → Accounts). |
| `TRUELAYER_ENVIRONMENT` | `sandbox` | `sandbox` or `live`. |
| `TRUELAYER_CLIENT_ID` | `sandbox-dayledger-1a2b3c` | From the TrueLayer console. |
| `TRUELAYER_CLIENT_SECRET` | `…` | Optional, **Debug builds only**: talk to the TrueLayer sandbox without a backend. Release builds blank it (`Config/Release.xcconfig`). See below. |
| `GOOGLE_IOS_CLIENT_ID` | `1234-abcd.apps.googleusercontent.com` | Google OAuth client of type iOS. |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | `https:/$()/xyz.supabase.co` | The DayLedger backend: accounts, DayLedger Pro, and the TrueLayer token exchange (see [`supabase/README.md`](supabase/README.md)). |

The App Group is derived automatically as `group.$(DL_BUNDLE_ID)`.

> In `.xcconfig` files `//` starts a comment, so never paste a URL into one.

## TrueLayer sandbox setup

1. Sign up at [console.truelayer.com](https://console.truelayer.com) and stay in the **Sandbox** environment.
2. Under **App settings**, copy the **client ID** into `Config/Local.xcconfig` (`TRUELAYER_CLIENT_ID`). Put the **client secret** in the backend's function secrets (`supabase secrets set TRUELAYER_CLIENT_ID=… TRUELAYER_CLIENT_SECRET=…`, see [`supabase/README.md`](supabase/README.md)) and deploy the `truelayer-token` function. For quick local sandbox work without a backend you can instead set `TRUELAYER_CLIENT_SECRET` in `Config/Local.xcconfig`; only Debug builds use it.
3. Under **Allowed redirect URIs**, add exactly:

   ```text
   dayledger://truelayer-callback
   ```

4. Make sure the **Data API** product is enabled (scopes `info accounts balance cards transactions offline_access`).
5. Run the app → **Settings → Connect a bank**. Pick **Mock Bank** and log in with the sandbox test credentials shown in the TrueLayer docs (commonly `john` / `doe`).

**About the client secret.** TrueLayer's token endpoint requires the client secret, and a secret shipped inside an app can be extracted. So the app never holds it in Release: tokens are exchanged and refreshed by the `truelayer-token` Edge Function (`supabase/functions/truelayer-token`), which adds the secret from its function secrets and passes the tokens through without storing them. The app calls it with the public anon key, so bank connections still need no DayLedger account. In code this is `BackendTrueLayerTokenExchanger` (`Packages/DayLedgerKit/Sources/BankKit/TrueLayerTokenExchanger.swift`). `DirectTrueLayerTokenExchanger`, which talks to TrueLayer with a local secret, only exists in Debug builds; `Config/Release.xcconfig` blanks `TRUELAYER_CLIENT_SECRET`, and CI plants a canary secret and fails if it reaches a Release build.

**Going live** requires TrueLayer to approve your application for production access, which may not be offered to individuals. Set `TRUELAYER_ENVIRONMENT = live` once approved. UK banks require re-confirming access every 90 days; the app shows a **Reconnect** prompt when that happens.

## Calendar

Visits and approved suggestions go to a calendar called **DayLedger**. **Settings → Calendar** chooses where:

- **Apple Calendar** (default): the calendars on the iPhone, through EventKit; the DayLedger calendar is created in the account new events go to (usually iCloud). Tap **Allow calendar access**. iOS 17's *write-only* access isn't enough, because DayLedger must find and update its own events instead of duplicating them, so the app asks for full access. Events are found again by a `dayledger://event/<id>` URL, so a reinstall doesn't create duplicates. From other calendars DayLedger reads only busy times.
- **Google Calendar** (optional): needs the Google Cloud setup below. Anyone who was already writing to Google before Apple Calendar support stays on Google.

Switching calendars rewrites the last 7 days of visits to the new one.

## Google Cloud OAuth setup (only for Google Calendar)

1. Create a project at [console.cloud.google.com](https://console.cloud.google.com).
2. **APIs & Services → Library**: enable the **Google Calendar API**.
3. **OAuth consent screen**: choose **External**, fill in the app name and your email, and add the scopes:
   - `https://www.googleapis.com/auth/calendar.app.created` (create and manage only calendars this app creates)
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly` (find the DayLedger calendar again after a reinstall)
   - `https://www.googleapis.com/auth/calendar.freebusy` (busy/free times only, used by the AI assistant)
4. Under **Test users**, add your own Google account.
5. **Credentials → Create credentials → OAuth client ID → iOS**. Enter your `DL_BUNDLE_ID` as the bundle ID and copy the client ID into `GOOGLE_IOS_CLIENT_ID`.
6. Run the app → **Settings → Sign in with Google**, then turn on **Write visits to calendar**.

Notes:

- iOS OAuth clients have no client secret. The app uses Authorization Code + PKCE through `ASWebAuthenticationSession`, and the redirect is the reversed client ID (`com.googleusercontent.apps.…:/oauth2redirect`), which the app derives automatically.
- While the consent screen is in **Testing**, Google expires refresh tokens after **7 days**, so you'll be asked to sign in again weekly. Publishing the app (and passing Google's verification for sensitive scopes) removes this.
- If Google rejects the narrow scopes above for your project, replace them with `https://www.googleapis.com/auth/calendar` in `GoogleOAuthConfiguration.defaultScopes` (`Packages/DayLedgerKit/Sources/CalendarKit/GoogleAuthService.swift`) and on the consent screen.

## App Group and signing

The widget reads today's spend from a shared **App Group** container.

1. In `Config/Local.xcconfig`, set `DL_BUNDLE_ID` and `DL_DEVELOPMENT_TEAM`.
2. In Xcode, select the **DayLedger** target → *Signing & Capabilities*. With automatic signing, Xcode registers the App ID and the `group.<your bundle ID>` App Group for you. If it doesn't, create the App Group in the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list/applicationGroup) and enable it on both App IDs (`<bundle id>` and `<bundle id>.widget`).
3. Do the same for the **DayLedgerWidget** target.
4. Run the app once and connect a bank, then add the widget from the home screen or lock screen.

Both entitlements files (`App/DayLedger.entitlements`, `Widget/DayLedgerWidget.entitlements`) are generated by XcodeGen from `project.yml` and committed.

## AI assistant

Optional, off by default, and part of DayLedger Pro. Users don't need an API key: suggestions run on the backend with DayLedger's own Anthropic key.

1. Backend: `supabase secrets set ANTHROPIC_API_KEY=…` (optionally `ANTHROPIC_MODEL`, default `claude-opus-5-5`, and `AI_DAILY_LIMIT`, default 20 requests per user per day) and deploy the `ai-suggest` function (see [`supabase/README.md`](supabase/README.md)).
2. In the app: **Settings → AI suggestions** → turn on. **Preview what would be sent** shows the exact JSON.
3. Open the **Suggest** tab → **Suggest events from my routine**. Approve or reject each suggestion (or **Approve all**), then **Add to calendar**. Only approved events are written, to the DayLedger calendar.

Details:

- The app sends only the anonymised `RoutineSummary`. The `ai-suggest` function (`supabase/functions/_shared/ai.ts`) checks the user's subscription and daily limit, re-validates the summary against an allowlist (so the endpoint can't be used as a general prompt proxy), builds the prompt and calls Anthropic with structured JSON output and the server-side refusal fallback (`fallbacks: "default"`). Neither the summary nor the answer is stored; only a per-day request count (`ai_usage`).
- Every suggestion is validated again on the device before you see it (future, within 14 days, 5–480 minutes, no clash with busy times, no duplicates).
- Earlier versions asked for your own Anthropic key; it is removed from the Keychain on upgrade.

## Architecture

MVVM with async/await, in Swift 6 language mode (complete data-race checking) for the app, the widget and the package. Feature logic lives in a local Swift package, split into modules with one responsibility each:

```text
Packages/DayLedgerKit/
  SharedModels   value types: transactions, visits, money, spend maths, widget snapshot
  Networking     HTTPClient protocol, error mapping, OAuth token types
  SecureStore    Keychain wrapper (the only module touching Security.framework)
  BankKit        TrueLayer OAuth, Data API client, categorisation, mock bank
  CalendarKit    Google OAuth (PKCE), Calendar API, visit/transaction matcher, event builder
  LocationKit    CoreLocation visit + significant-change monitoring, MapKit place lookup
  AIKit          AIProvider protocol, Anthropic provider, anonymised summary, proposal parser
  AccountKit     Supabase Auth, PostgREST sync client, entitlement, end-to-end sync encryption
App/             SwiftUI views, view models, SwiftData persistence, app services
Widget/          WidgetKit extension (reads a JSON snapshot from the App Group)
```

Key flows:

- **Bank sync**: `TransactionSyncService` → `BankService.fetchTransactions` → SwiftData (`TransactionRepository`) → widget snapshot → calendar re-sync.
- **Visits**: iOS wakes the app → `LocationLoggingService` stores the visit, resolves the place, then `CalendarSyncService` writes it.
- **No duplicates**: Google event IDs are derived from visit IDs (`CalendarEventID`). Inserting an existing ID returns 409 and the app updates instead. A content hash skips events that haven't changed.
- **Local-first**: nothing requires an account. `AppGate.proAccess` decides only whether DayLedger Pro features (cloud sync, AI suggestions) are available; sign-in and the paywall are sheets opened from Settings or from a Pro feature.
- **Cloud sync** (signed in): `CloudSyncService` pulls changes, then pushes. Transactions, and visits when visit sync is on, are sealed with AES-256-GCM using the account's sync key (`SyncKeyManager`, iCloud Keychain) before upload; see `docs/backend-contract.md`, "Encryption".
- **One sync pipeline**: every trigger (foreground, background task, a visit, a bank sync, sign-in, a new subscription) asks `SyncCoordinator` for the steps it needs. Steps always run as bank → places → widget → calendar → entitlement → cloud, and overlapping requests are merged, so nothing runs twice in parallel.
- **Persistence**: SwiftData with a versioned schema (`App/Persistence/SchemaVersions.swift`, `DayLedgerMigrationPlan`). To change a stored model, add a schema version and a migration stage, and add a test that opens a store written by the previous version (`PersistenceMigrationTests`). Rows to upload are found by a `needsCloudPush` flag; deletions waiting for the cloud are a SwiftData model. A store that can't be opened is moved aside (`DayLedger.store.unreadable-<time>`, never deleted) and replaced, and everything is fetched again.
- **Resumable pulls**: each page of cloud changes is applied and its cursor saved before the next page is fetched.
- **Logging and metrics**: `os.Logger` (subsystem `app.dayledger`; categories `sync`, `persistence`, `subscriptions`, `background`, `metrics`), private by default. MetricKit payloads (crashes, hangs, CPU, background location time) are logged and the latest 20 are kept in `Caches/MetricKit`; nothing is sent anywhere.
- **Background processing**: `BGProcessingTask` (`app.dayledger.processing`, needs network) runs the full pipeline when iOS allows longer work, e.g. a first cloud sync.
- **Background refresh**: `BGAppRefreshTask` (`app.dayledger.refresh`) fetches transactions, updates the widget and syncs the calendar when iOS allows.

## Privacy and security

- Tokens and API keys are stored **only in the Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud). The one exception is the end-to-end **sync key**, which is deliberately kept in iCloud Keychain so your other devices can read your synced data.
- No secrets are in the source code, the repository or Release builds. IDs come from the git-ignored `Config/Local.xcconfig`; the TrueLayer client secret lives only in the backend's function secrets.
- **No account needed.** Today, widgets, bank connections, Places and the calendar diary work entirely on the device. Location, calendar writing and AI are each **off until you turn them on**.
- **With an account (DayLedger Pro):** transactions sync to your account, **end-to-end encrypted** on the device: the server stores only ciphertext and the key's fingerprint, and can't read merchants, amounts, places or coordinates. **Visits are only uploaded if you turn on visit sync** (off by default, account-wide). Preferences (which features are on) sync unencrypted. Your email address and subscription status are stored with the account.
- **Upgrading from an earlier version**: data that older versions uploaded in plaintext is re-uploaded encrypted on the first sync (which erases the plaintext). Visits that older versions uploaded wait for your choice in Settings or Places: keep them (encrypted) or remove them from your account.
- If the sync key is lost on every device (for example iCloud Keychain turned off everywhere), the synced copy can't be read by anyone, including DayLedger. **Settings → Cloud sync → Start over with this iPhone's data** deletes it and uploads again with a new key.
- The AI receives an anonymised summary only: no coordinates, addresses, account details, individual transactions or event titles. A unit test asserts this.
- **Settings → Privacy & your data** explains what is collected and where it goes. **Delete all my data** deletes your DayLedger account (if any) and its sync key, stops location logging, revokes the bank consent and the Google sign-in, optionally deletes the DayLedger calendar (Apple and/or Google), and wipes the local database, widget data, Keychain items and preferences.
- No analytics, no ads, no tracking. The only server of our own is the optional account backend (`supabase/`).
- **Privacy manifests**: `App/PrivacyInfo.xcprivacy` (UserDefaults reasons `CA92.1` and `1C8F.1`; collected data: email address, user ID, purchase history, other financial info and precise location, all linked to the account, used only for app functionality, never for tracking) and `Widget/PrivacyInfo.xcprivacy` (nothing collected, no required-reason APIs). Keep the App Store Connect privacy label in line with them. Financial info and location are end-to-end encrypted but declared anyway, to be conservative.

## Tests and CI

Unit tests:

- `CalendarKitTests`: transaction-to-visit matching rules, calendar event building, Google Calendar API client (create/update, 401 retry, 403), PKCE, the Apple Calendar destination against an in-memory event store (access, calendar reuse, no duplicates).
- `AIKitTests`: AI proposal parsing and validation, summary anonymisation, the backend AI provider (what's sent, error mapping). The Anthropic call itself is tested with the Edge Function.
- `BankKitTests`: TrueLayer parsing, categorisation, spending maths, token refresh, expired consent, the backend token exchange (no secret sent, error mapping).
- `AccountKitTests`: auth, entitlement, PostgREST client, encrypted sync rows (no plaintext uploaded, legacy rows read), AES-GCM sealing (tampering, wrong key, rows bound to user and id), sync key registration races.
- `SharedModelsTests`: widget snapshot, visit merging.
- `DayLedgerTests`: Today view model (offline cache), pending→settled replacement, end-to-end calendar sync without duplicates, cloud sync (encryption, plaintext → encrypted upgrade, missing key, opt-in visit sync, start over, resumable pulls), local-first gating, token exchanger selection, the sync coordinator (order, merging), store migration from schema V1 and recovery from an unreadable store, Apple Calendar sync (no duplicates, reinstall, no access, switching calendars, default for new vs existing users).
- `supabase/`: Deno tests for the Edge Functions (including `truelayer-token`) and pgTAP tests for the schema (including `06_encryption.test.sql`), run by `.github/workflows/backend.yml`.
- `DayLedgerUITests`: launches the app with mock data (Today, Privacy, Places, Suggest).

To run them locally, use Xcode (⌘U on the **DayLedger** scheme) for app and UI tests, and the **DayLedgerKit-Package** scheme for the package tests. Or from the command line:

```bash
xcodebuild test -project DayLedger.xcodeproj -scheme DayLedger -destination 'platform=iOS Simulator,name=iPhone 16'
```

```bash
cd Packages/DayLedgerKit && xcodebuild test -scheme DayLedgerKit-Package -destination 'platform=iOS Simulator,name=iPhone 16'
```

`.github/workflows/ios.yml` runs on every push on a macOS runner: it generates the project, runs the package tests and the app + UI tests on a simulator, and builds an unsigned Release build for a physical device with a canary `TRUELAYER_CLIENT_SECRET`, failing if the secret (or the Debug-only direct exchanger) ends up in the Release app.

## What can't be tested without real credentials or a device

| Area | Why | How to check |
|---|---|---|
| TrueLayer login, token exchange and refresh against the real sandbox | Needs your sandbox client ID/secret and the redirect URI registered | Connect **Mock Bank**, pull to refresh, wait an hour (tokens expire) and refresh again |
| Real bank data (live) | Needs TrueLayer production approval | Check merchant names, categories, pending → settled, and timestamps for your bank |
| 90-day consent expiry | Real time | The **Reconnect** prompt should appear; covered by unit tests with simulated 401/403 |
| Apple Calendar permission and real calendars | The permission prompt and EventKit need a device or a simulator with a person tapping | Settings → Calendar → Allow calendar access → Full Access, turn on writing, **Sync now**: a DayLedger calendar appears in the Calendar app. Delete the app and reinstall: no duplicate events |
| AI suggestions end to end | Needs `ANTHROPIC_API_KEY` on the backend and a Pro account | Suggest → approve one → it appears in the DayLedger calendar; the 21st request of the day says the limit is reached |
| Google sign-in and the narrow calendar scopes | Needs your OAuth client; scope acceptance depends on your Google project | Sign in, enable calendar writing, tap **Sync now**, check the DayLedger calendar appears |
| Google "Testing" 7-day refresh token expiry | Real time | After a week, Settings should ask you to sign in again |
| Visit monitoring and significant location changes | Simulator can't produce real visits; background relaunch only happens on a device | Enable location with **Always**, go about your day, check the Places tab and calendar |
| "Always" permission upgrade prompt | iOS shows it once, with its own timing | Settings → Location → Allow logging in the background |
| MapKit place names | Accuracy depends on real coordinates and Apple's POI data | Compare Places entries with where you actually were |
| Background app refresh | iOS schedules it heuristically; never on demand in normal use | In Xcode's debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.dayledger.refresh"]` |
| Background processing task | Same | Same command with `@"app.dayledger.processing"` |
| MetricKit payloads | Delivered by iOS about once a day on a device | Xcode → Debug → Simulate MetricKit Payloads, then check `Caches/MetricKit` and the `metrics` log category |
| Store migration on a real upgrade | Needs a device with the previous build's data | Install the previous build, use it, install this one: data and pending uploads survive (also covered by `PersistenceMigrationTests`) |
| Widgets with real data and App Group sharing | Needs signing with your team (CI builds unsigned) | Add the widgets, make a purchase, refresh the app |
| Lock screen privacy redaction | Device-only behaviour | Lock the phone with the widget on the lock screen |
| AI suggestions | Needs your Anthropic API key and a few weeks of visits | Preview the summary, then Suggest and approve one |
| Keychain behaviour | CI runs unsigned tests that use an in-memory store | Sign in, force-quit, reopen: you stay signed in |
| End-to-end sync across devices (iCloud Keychain) | Needs two signed-in devices with iCloud Keychain on | Sign in on phone A, sync; sign in on phone B: its transactions appear. Turn iCloud Keychain off on B and reinstall: Settings shows "Waiting for your encryption key" |
| Upgrade of existing cloud data to encrypted | Needs an account with data from the previous version | Before upgrading, check a row in the Supabase table editor has `merchant` set; after the first sync on the new version, `payload` is set and `merchant` is null |
| `truelayer-token` against TrueLayer | Needs the function deployed with your TrueLayer secrets | Leave `TRUELAYER_CLIENT_SECRET` empty, connect Mock Bank, pull to refresh after an hour |

## Known limitations

- **Encryption depends on iCloud Keychain**: a device without iCloud Keychain can't read the synced copy (it says so and offers to start over). There is no recovery phrase yet.
- **Mixed app versions**: an older version still on another device keeps uploading plaintext; newer devices re-encrypt those rows on their next sync. Lapsed subscribers' old plaintext rows stay until they subscribe again (writes need an entitlement); "Delete account" removes them.
- **`truelayer-token` has no rate limiting of its own** beyond Supabase's gateway; it only works for holders of a valid TrueLayer code or refresh token. Consider App Attest before a public launch.

- **Widget freshness**: widgets update when the app syncs (on open, pull-to-refresh, background refresh, or a visit wake-up), not the instant a payment happens. Real-time updates would need a server and push notifications.
- **Transaction times**: settled transactions often carry only a date. Those are matched to visits by name only.
- **Matching is best-effort**: a purchase is linked to a visit by merchant/place name similarity and time. When the name doesn't match, a purchase can still be attached as "likely" if it's the only named place you were at and the purchase is the in-person kind.
- **Credit card repayments** paid from a current account may count as spending, because banks don't reliably mark them as transfers.
- **Visit names** come from the nearest point of interest and can be wrong in busy areas (for example shopping centres).

## Licence

Copyright (c) 2026 arnaldinhobjj. All rights reserved. This code is publicly visible for reference only and may not be used, copied, modified or distributed without written permission. See [LICENSE](LICENSE).
