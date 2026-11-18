import Foundation

/// Implements "Delete all my data": revokes remote access where possible and wipes
/// everything stored on this device.
@MainActor
struct DataEraser {
    let environment: AppEnvironment

    struct Report {
        var failures: [String] = []
    }

    func eraseAll(deleteGoogleCalendar: Bool) async -> Report {
        var report = Report()

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

        // 3. Every Keychain item (bank tokens, Google tokens, AI API keys).
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
        return report
    }
}
