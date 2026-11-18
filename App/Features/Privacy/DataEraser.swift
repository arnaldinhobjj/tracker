import Foundation

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
}
