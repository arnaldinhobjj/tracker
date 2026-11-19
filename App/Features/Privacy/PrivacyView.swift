import SwiftUI

struct PrivacyView: View {
    let eraser: DataEraser
    var onErased: () -> Void

    @State private var isConfirming = false
    @State private var isErasing = false
    @State private var resultMessage: String?
    @State private var resultTitle = "Data deleted"
    @State private var deleteGoogleCalendar = true

    var body: some View {
        List {
            Section("What DayLedger collects") {
                PrivacyRow(icon: "building.columns", title: "Bank transactions",
                           detail: "Merchant, amount, time and category for accounts you connect. Read-only: DayLedger cannot move money.")
                PrivacyRow(icon: "location", title: "Places you visit",
                           detail: "Only if you turn on location logging. Uses iOS visit detection (not continuous GPS) to record arrival and departure times, the visit's coordinates and a nearby place name.")
                PrivacyRow(icon: "calendar", title: "Calendar",
                           detail: "Only if you sign in with Google. DayLedger writes to its own \"DayLedger\" calendar and reads only free/busy times from your other calendars.")
                PrivacyRow(icon: "sparkles", title: "AI suggestions (optional)",
                           detail: "Only if you add your own API key and ask for suggestions.")
                PrivacyRow(icon: "person.crop.circle", title: "Your DayLedger account (optional)",
                           detail: "Only if you create one: your email address and your DayLedger Pro subscription status. Everything else in DayLedger works without an account.")
            }

            Section("Where it goes") {
                PrivacyRow(icon: "iphone", title: "On this device",
                           detail: "Transactions and visits are stored on your iPhone so DayLedger works offline. Sign-in tokens and API keys are kept in the iOS Keychain and never leave the device except to the service they belong to.")
                PrivacyRow(icon: "lock.icloud", title: "Your DayLedger account (DayLedger Pro)",
                           detail: "If you sign in, transactions sync to your account so they survive a new iPhone. Visits sync only if you turn on visit sync. Both are end-to-end encrypted on your iPhone before upload, with a key kept in your iCloud Keychain: DayLedger's servers store only ciphertext and can't read merchants, amounts, places or coordinates. Your preferences (such as which features are on) are synced unencrypted. Bank, Google and AI keys are never uploaded.")
                PrivacyRow(icon: "arrow.left.arrow.right", title: "TrueLayer and your bank",
                           detail: "TrueLayer passes transactions from your bank straight to the app. Your bank password is entered on your bank's own page, never in DayLedger. When connecting or refreshing access, DayLedger's server adds the app's TrueLayer credentials to the request; it passes the access tokens through without storing or logging them.")
                PrivacyRow(icon: "calendar.badge.plus", title: "Google Calendar",
                           detail: "Visit entries (place, times, matching spend) are written to your DayLedger calendar in your Google account.")
                PrivacyRow(icon: "sparkles", title: "AI provider",
                           detail: "When you ask for suggestions, an anonymised summary is sent: place names with typical days and times, spending per category rounded to £5, and busy/free blocks. Never coordinates, addresses, account numbers, individual transactions or event titles.")
                PrivacyRow(icon: "xmark.shield", title: "No tracking",
                           detail: "DayLedger has no analytics and no ads, and never sells your data.")
            }

            Section {
                Toggle("Also delete the DayLedger calendar from Google", isOn: $deleteGoogleCalendar)
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    if isErasing {
                        ProgressView()
                    } else {
                        Label("Delete all my data", systemImage: "trash")
                    }
                }
                .disabled(isErasing)
                .accessibilityIdentifier("deleteAllData")
            } footer: {
                Text("Deletes your DayLedger account and everything synced to it (if you're signed in), stops location logging, disconnects your banks, signs out of Google and AI, deletes every transaction and visit on this device, and clears all keys from the Keychain. An App Store subscription must be cancelled separately in Settings → Apple ID → Subscriptions. Data already held by your bank, Google or an AI provider is governed by their own policies.")
            }
        }
        .navigationTitle("Privacy & your data")
        .confirmationDialog("Delete all your DayLedger data?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert(resultTitle, isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { onErased() }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func erase() {
        isErasing = true
        Task {
            let report = await eraser.eraseAll(deleteGoogleCalendar: deleteGoogleCalendar)
            isErasing = false
            if let reason = report.abortedReason {
                resultTitle = "Nothing was deleted"
                resultMessage = reason
                return
            }
            resultTitle = "Data deleted"
            resultMessage = report.failures.isEmpty
                ? "All DayLedger data has been removed from this device."
                : "Most data was removed, but some items failed:\n" + report.failures.joined(separator: "\n")
        }
    }
}

private struct PrivacyRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
