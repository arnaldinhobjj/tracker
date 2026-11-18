import BankKit
import Foundation
import SharedModels

/// Fetches transactions from the bank and stores them locally.
/// Used by the Today screen, pull-to-refresh and background refresh.
@MainActor
final class TransactionSyncService {
    struct Outcome {
        var fetchedCount = 0
        var failures: [BankConnectionFailure] = []
        var storageError: Error?
    }

    /// How far back the first sync goes. Later syncs overlap the previous one by `overlap`.
    static let initialWindow: TimeInterval = 30 * 24 * 3600
    static let overlap: TimeInterval = 3 * 24 * 3600

    private let bank: BankService
    private let repository: TransactionRepository
    private let defaults: UserDefaults
    private let lastSyncKey = "bank.lastSuccessfulSync"
    private var inFlight: Task<Outcome, Never>?

    /// Called after every successful sync (the widget hooks in here).
    var onSynced: (@MainActor () -> Void)?

    init(bank: BankService, repository: TransactionRepository, defaults: UserDefaults) {
        self.bank = bank
        self.repository = repository
        self.defaults = defaults
    }

    var lastSuccessfulSync: Date? {
        defaults.object(forKey: lastSyncKey) as? Date
    }

    /// Runs a sync, or joins the one already running.
    func sync(now: Date = Date()) async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await performSync(now: now) }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func performSync(now: Date) async -> Outcome {
        guard !bank.connections().isEmpty else { return Outcome() }
        let since = lastSuccessfulSync.map { $0.addingTimeInterval(-Self.overlap) } ?? now.addingTimeInterval(-Self.initialWindow)

        let result = await bank.fetchTransactions(since: since, until: now)
        var outcome = Outcome(fetchedCount: result.transactions.count, failures: result.failures)
        do {
            try repository.apply(result.transactions, refreshedAccountIDs: result.refreshedAccountIDs, now: now)
            if result.failures.isEmpty {
                defaults.set(now, forKey: lastSyncKey)
            }
            onSynced?()
        } catch {
            outcome.storageError = error
        }
        return outcome
    }

    func reset() {
        defaults.removeObject(forKey: lastSyncKey)
    }
}
