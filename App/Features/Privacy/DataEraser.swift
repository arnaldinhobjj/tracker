import Foundation
import SecureStore

/// Implements "Delete all my data": revokes remote access where possible and wipes
/// everything stored on this device.
@MainActor
struct DataEraser {
    let environment: AppEnvironment

    struct Report {
        var failures: [String] = []
        /// The DayLedger account (and its cloud copy) was deleted.
        var deletedAccount = false
        /// Nothing was erased because the cloud account couldn't be deleted first.
        var abortedReason: String?
    }

    /// Erases everything. When signed in to a DayLedger account, the account and its cloud copy
    /// are deleted first (if that fails nothing else is touched, so it can be retried), and the
    /// user is signed out at the end.
    func eraseAll(deleteGoogleCalendar: Bool) async -> Report {
        var report = Report()
        let account = environment.account

        // Cloud account first: it needs the session that step 3 removes from the Keychain.
        let hasCloudAccount = account.isSignedIn && !account.isDeveloperAccount
        if hasCloudAccount {
            guard let rest = environment.cloudREST else {
                report.abortedReason = "Your DayLedger account can't be reached from this build, so nothing was deleted."
                return report
            }
            do {
                try await rest.deleteAccount()
                report.deletedAccount = true
            } catch {
                report.abortedReason = "Couldn't delete your DayLedger account (\(UserFacingError(error).message)) Nothing was deleted; please try again."
                return report
            }
        }

        // 0. Stop collecting before deleting.
        environment.locationLogging.setEnabled(false)
        environment.settings.calendarWritingEnabled = false

        // Google: optionally remove the DayLedger calendar, then revoke the sign-in.
        if deleteGoogleCalendar && environment.googleAuth.isSignedIn {
            do {
                try await environment.calendarSync.deleteCalendar()
            } catch {
                report.failures.append("Google calendar: \(UserFacingError(error).message)")
            }
        }
        await environment.googleAuth.signOut()
        environment.calendarSync.forgetCalendar()

        // 1. Revoke bank consent with TrueLayer and forget the connections.
        await environment.bankService.disconnectAll()

        // 2. Local database (transactions and everything else cached).
        do {
            try environment.transactionRepository.deleteAll()
            try environment.visitRepository.deleteAll()
        } catch {
            report.failures.append("Local database: \(error.localizedDescription)")
        }

        // 3. Every Keychain item (bank tokens, Google tokens, AI API keys, the account session).
        do {
            try environment.secureStore.removeAll()
        } catch {
            report.failures.append("Keychain: \(error.localizedDescription)")
        }

        // 4. The widget's copy of today's spending.
        environment.widgetPublisher.clear()

        // 5. Preferences and sync bookkeeping.
        environment.transactionSync.reset()
        for key in environment.defaults.dictionaryRepresentation().keys {
            environment.defaults.removeObject(forKey: key)
        }
        environment.settings.resetToDefaults()

        // 6. The account no longer exists: forget it on this device.
        if hasCloudAccount {
            environment.subscriptions.reset()
            await account.signOut()
        }
        return report
    }

    // MARK: Switching accounts

    /// Key in `UserDefaults` holding the id of the last DayLedger account signed in on this device.
    static let lastAccountKey = "account.lastSignedInUserID"

    /// Called after a sign-in. When a *different* account was signed in on this device before,
    /// everything the previous person left here is wiped (bank and Google connections, cached
    /// transactions and visits, AI keys, widget, preferences) so none of it is shown to, or
    /// uploaded into, the new account. Their cloud copy is untouched. The new session is kept.
    /// Returns true when data was wiped.
    @discardableResult
    func wipeIfDifferentAccount(newUserID: UUID) async -> Bool {
        let defaults = environment.defaults
        let previous = defaults.string(forKey: Self.lastAccountKey).flatMap(UUID.init(uuidString:))
        defer { defaults.set(newUserID.uuidString, forKey: Self.lastAccountKey) }
        guard let previous, previous != newUserID else { return false }

        environment.locationLogging.setEnabled(false)
        environment.settings.calendarWritingEnabled = false
        await environment.googleAuth.signOut()
        environment.calendarSync.forgetCalendar()
        await environment.bankService.disconnectAll()
        try? environment.transactionRepository.deleteAll()
        try? environment.visitRepository.deleteAll()

        // Every Keychain item except the new account's session.
        let store = environment.secureStore
        let session = try? store.data(for: SecureStoreKey.supabaseSession)
        try? store.removeAll()
        if let session { try? store.set(session, for: SecureStoreKey.supabaseSession) }

        environment.widgetPublisher.clear()
        environment.transactionSync.reset()
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        environment.settings.resetToDefaults()
        return true
    }
}
