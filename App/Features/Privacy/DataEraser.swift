import Foundation

/// Implements "Delete all my data": revokes remote access where possible and wipes
/// everything stored on this device.
@MainActor
struct DataEraser {
    let environment: AppEnvironment

    struct Report {
        var failures: [String] = []
    }

    func eraseAll() async -> Report {
        var report = Report()

        // 1. Revoke bank consent with TrueLayer and forget the connections.
        await environment.bankService.disconnectAll()

        // 2. Local database (transactions and everything else cached).
        do {
            try environment.transactionRepository.deleteAll()
        } catch {
            report.failures.append("Local database: \(error.localizedDescription)")
        }

        // 3. Every Keychain item (bank tokens, Google tokens, AI API keys).
        do {
            try environment.secureStore.removeAll()
        } catch {
            report.failures.append("Keychain: \(error.localizedDescription)")
        }

        // 4. Preferences and sync bookkeeping.
        environment.transactionSync.reset()
        for key in environment.defaults.dictionaryRepresentation().keys {
            environment.defaults.removeObject(forKey: key)
        }
        return report
    }
}
