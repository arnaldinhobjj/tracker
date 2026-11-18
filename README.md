# DayLedger

An iOS app (SwiftUI, iOS 17+) that combines your spending, the places you visit and Google Calendar:

- **Today**: total spent today and today's transactions from your UK bank (Open Banking via TrueLayer), cached offline.
- **Widgets**: home screen (small, medium) and lock screen (rectangular, inline, circular) widgets showing today's spend.
- **Places**: battery-friendly visit logging that writes entries like "At Costa Coffee · £3.40, 09:10–09:45" to a dedicated **DayLedger** Google calendar.
- **Suggest** (optional): an AI assistant, using your own API key, that proposes events from your routine. Nothing is added until you approve it.

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
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple Developer account to run on a device. A paid membership is recommended: App Groups (needed by the widget) and long-lived installs are not reliable with a free "Personal Team".
- A TrueLayer developer account (free sandbox)
- A Google Cloud project (free)

## Build and run

The Xcode project is generated from `project.yml`, so it never has merge conflicts and contains no secrets.

```bash
brew install xcodegen
```

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Edit `Config/Local.xcconfig` (see [Configuration](#configuration)), then:

```bash
xcodegen generate
```

```bash
open DayLedger.xcodeproj
```

Select the **DayLedger** scheme and run. Without any credentials the app still launches: the Today screen asks you to connect a bank, and settings explain what's missing.

To try the UI with fake data and no credentials, add `-UITestMockData` under *Scheme → Run → Arguments Passed On Launch*. This uses an in-memory store and a mock bank.

Run `xcodegen generate` again whenever you pull changes that touch `project.yml` or add or remove files.

## Configuration

All IDs live in `Config/Local.xcconfig`, which is **git-ignored**. `Config/Base.xcconfig` holds empty defaults and includes it. Values reach the app through `Info.plist` and are read by `App/Support/AppConfiguration.swift`.

| Setting | Example | Purpose |
|---|---|---|
| `DL_BUNDLE_ID` | `com.yourname.dayledger` | App bundle ID. The widget is `$(DL_BUNDLE_ID).widget`. |
| `DL_DEVELOPMENT_TEAM` | `ABCDE12345` | Your Apple Team ID (Xcode → Settings → Accounts). |
| `TRUELAYER_ENVIRONMENT` | `sandbox` | `sandbox` or `live`. |
| `TRUELAYER_CLIENT_ID` | `sandbox-dayledger-1a2b3c` | From the TrueLayer console. |
| `TRUELAYER_CLIENT_SECRET` | `…` | **Sandbox / personal use only**, see below. |
| `GOOGLE_IOS_CLIENT_ID` | `1234-abcd.apps.googleusercontent.com` | Google OAuth client of type iOS. |

The App Group is derived automatically as `group.$(DL_BUNDLE_ID)`.

> In `.xcconfig` files `//` starts a comment, so never paste a URL into one.

## TrueLayer sandbox setup

1. Sign up at [console.truelayer.com](https://console.truelayer.com) and stay in the **Sandbox** environment.
2. Under **App settings**, copy the **client ID** and **client secret** into `Config/Local.xcconfig`.
3. Under **Allowed redirect URIs**, add exactly:

   ```text
   dayledger://truelayer-callback
   ```

4. Make sure the **Data API** product is enabled (scopes `info accounts balance cards transactions offline_access`).
5. Run the app → **Settings → Connect a bank**. Pick **Mock Bank** and log in with the sandbox test credentials shown in the TrueLayer docs (commonly `john` / `doe`).

**About the client secret.** TrueLayer's token endpoint requires the client secret, and a secret shipped inside an app can be extracted. That's acceptable for the sandbox and for a personal build on your own phone, which is the agreed scope here. It is **not** acceptable for an App Store release. The exchange sits behind the `TrueLayerTokenExchanging` protocol (`Packages/DayLedgerKit/Sources/BankKit/TrueLayerTokenExchanger.swift`). For production, implement one that calls a small backend you own (for example a Cloudflare Worker) holding the secret, and leave `TRUELAYER_CLIENT_SECRET` empty.

**Going live** requires TrueLayer to approve your application for production access, which may not be offered to individuals. Set `TRUELAYER_ENVIRONMENT = live` once approved. UK banks require re-confirming access every 90 days; the app shows a **Reconnect** prompt when that happens.

## Google Cloud OAuth setup

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

1. In `Config/Local.xcconfig`, set `DL_BUNDLE_ID` and `DL_DEVELOPMENT_TEAM`, then run `xcodegen generate`.
2. In Xcode, select the **DayLedger** target → *Signing & Capabilities*. With automatic signing, Xcode registers the App ID and the `group.<your bundle ID>` App Group for you. If it doesn't, create the App Group in the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list/applicationGroup) and enable it on both App IDs (`<bundle id>` and `<bundle id>.widget`).
3. Do the same for the **DayLedgerWidget** target.
4. Run the app once and connect a bank, then add the widget from the home screen or lock screen.

Both entitlements files (`App/DayLedger.entitlements`, `Widget/DayLedgerWidget.entitlements`) are generated by XcodeGen from `project.yml`.

## AI assistant

Optional and off by default.

1. Get an API key from [console.anthropic.com](https://console.anthropic.com). Usage is billed to your Anthropic account.
2. **Settings → AI assistant → Connect AI**, paste the key and tap **Save key**. It's stored only in the iOS Keychain.
3. Tap **Preview what would be sent** to see the exact JSON.
4. Open the **Suggest** tab → **Suggest events from my routine**. Approve or reject each suggestion (or **Approve all**), then **Add to calendar**. Only approved events are written, to the DayLedger calendar.

Details:

- Model: `claude-opus-5-5`, with structured JSON output and Anthropic's server-side refusal fallback (`fallbacks: "default"`), so a safety refusal is retried on a fallback model within the same request.
- Every suggestion is validated before you see it (future, within 14 days, 5–480 minutes, no clash with busy times, no duplicates).
- Other providers can be added by implementing `AIProvider` (`Packages/DayLedgerKit/Sources/AIKit/AIProvider.swift`) and adding it to `AppEnvironment.aiProviders`.

## Architecture

MVVM with async/await. Feature logic lives in a local Swift package, split into modules with one responsibility each:

```text
Packages/DayLedgerKit/
  SharedModels   value types: transactions, visits, money, spend maths, widget snapshot
  Networking     HTTPClient protocol, error mapping, OAuth token types
  SecureStore    Keychain wrapper (the only module touching Security.framework)
  BankKit        TrueLayer OAuth, Data API client, categorisation, mock bank
  CalendarKit    Google OAuth (PKCE), Calendar API, visit/transaction matcher, event builder
  LocationKit    CoreLocation visit + significant-change monitoring, MapKit place lookup
  AIKit          AIProvider protocol, Anthropic provider, anonymised summary, proposal parser
App/             SwiftUI views, view models, SwiftData persistence, app services
Widget/          WidgetKit extension (reads a JSON snapshot from the App Group)
```

Key flows:

- **Bank sync**: `TransactionSyncService` → `BankService.fetchTransactions` → SwiftData (`TransactionRepository`) → widget snapshot → calendar re-sync.
- **Visits**: iOS wakes the app → `LocationLoggingService` stores the visit, resolves the place, then `CalendarSyncService` writes it.
- **No duplicates**: Google event IDs are derived from visit IDs (`CalendarEventID`). Inserting an existing ID returns 409 and the app updates instead. A content hash skips events that haven't changed.
- **Background refresh**: `BGAppRefreshTask` (`app.dayledger.refresh`) fetches transactions, updates the widget and syncs the calendar when iOS allows.

## Privacy and security

- Tokens and API keys are stored **only in the Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud).
- No secrets are in the source code or the repository. IDs come from the git-ignored `Config/Local.xcconfig`.
- Location, calendar writing and AI are each **off until you turn them on**.
- The AI receives an anonymised summary only: no coordinates, addresses, account details, individual transactions or event titles. A unit test asserts this.
- **Settings → Privacy & your data** explains what is collected and where it goes. **Delete all my data** stops location logging, revokes the bank consent and the Google sign-in, optionally deletes the DayLedger Google calendar, and wipes the local database, widget data, Keychain items and preferences.
- No analytics, ads or servers of our own.

## Tests and CI

Unit tests:

- `CalendarKitTests`: transaction-to-visit matching rules, calendar event building, Calendar API client (create/update, 401 retry, 403), PKCE.
- `AIKitTests`: AI proposal parsing and validation, summary anonymisation, Anthropic request and response handling (refusal, truncation, bad key).
- `BankKitTests`: TrueLayer parsing, categorisation, spending maths, token refresh, expired consent.
- `SharedModelsTests`: widget snapshot, visit merging.
- `DayLedgerTests`: Today view model (offline cache), pending→settled replacement, end-to-end calendar sync without duplicates.
- `DayLedgerUITests`: launches the app with mock data (Today, Privacy, Places, Suggest).

To run them locally, use Xcode (⌘U on the **DayLedger** scheme) for app and UI tests, and the **DayLedgerKit-Package** scheme for the package tests. Or from the command line:

```bash
xcodebuild test -project DayLedger.xcodeproj -scheme DayLedger -destination 'platform=iOS Simulator,name=iPhone 16'
```

```bash
cd Packages/DayLedgerKit && xcodebuild test -scheme DayLedgerKit-Package -destination 'platform=iOS Simulator,name=iPhone 16'
```

`.github/workflows/ios.yml` runs on every push on a macOS runner: it generates the project, runs the package tests and the app + UI tests on a simulator, and builds an unsigned Release build for a physical device.

## What can't be tested without real credentials or a device

| Area | Why | How to check |
|---|---|---|
| TrueLayer login, token exchange and refresh against the real sandbox | Needs your sandbox client ID/secret and the redirect URI registered | Connect **Mock Bank**, pull to refresh, wait an hour (tokens expire) and refresh again |
| Real bank data (live) | Needs TrueLayer production approval | Check merchant names, categories, pending → settled, and timestamps for your bank |
| 90-day consent expiry | Real time | The **Reconnect** prompt should appear; covered by unit tests with simulated 401/403 |
| Google sign-in and the narrow calendar scopes | Needs your OAuth client; scope acceptance depends on your Google project | Sign in, enable calendar writing, tap **Sync now**, check the DayLedger calendar appears |
| Google "Testing" 7-day refresh token expiry | Real time | After a week, Settings should ask you to sign in again |
| Visit monitoring and significant location changes | Simulator can't produce real visits; background relaunch only happens on a device | Enable location with **Always**, go about your day, check the Places tab and calendar |
| "Always" permission upgrade prompt | iOS shows it once, with its own timing | Settings → Location → Allow logging in the background |
| MapKit place names | Accuracy depends on real coordinates and Apple's POI data | Compare Places entries with where you actually were |
| Background app refresh | iOS schedules it heuristically; never on demand in normal use | In Xcode's debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.dayledger.refresh"]` |
| Widgets with real data and App Group sharing | Needs signing with your team (CI builds unsigned) | Add the widgets, make a purchase, refresh the app |
| Lock screen privacy redaction | Device-only behaviour | Lock the phone with the widget on the lock screen |
| AI suggestions | Needs your Anthropic API key and a few weeks of visits | Preview the summary, then Suggest and approve one |
| Keychain behaviour | CI runs unsigned tests that use an in-memory store | Sign in, force-quit, reopen: you stay signed in |

## Known limitations

- **Widget freshness**: widgets update when the app syncs (on open, pull-to-refresh, background refresh, or a visit wake-up), not the instant a payment happens. Real-time updates would need a server and push notifications.
- **Transaction times**: settled transactions often carry only a date. Those are matched to visits by name only.
- **Matching is best-effort**: a purchase is linked to a visit by merchant/place name similarity and time. When the name doesn't match, a purchase can still be attached as "likely" if it's the only named place you were at and the purchase is the in-person kind.
- **Credit card repayments** paid from a current account may count as spending, because banks don't reliably mark them as transfers.
- **Visit names** come from the nearest point of interest and can be wrong in busy areas (for example shopping centres).

## Licence

Copyright (c) 2026 arnaldinhobjj. All rights reserved. This code is publicly visible for reference only and may not be used, copied, modified or distributed without written permission. See [LICENSE](LICENSE).
