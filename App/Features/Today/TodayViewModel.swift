import BankKit
import Foundation
import Observation
import SharedModels

@MainActor
@Observable
final class TodayViewModel {
    private(set) var transactions: [BankTransaction] = []
    private(set) var totalSpentMinor = 0
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var hasConnection = false
    var error: UserFacingError?

    private let repository: TransactionRepository
    private let bank: BankService
    private let sync: TransactionSyncService
    private let calendar: Calendar
    private let now: () -> Date

    /// Don't hit the bank more often than this when the screen reappears.
    static let staleAfter: TimeInterval = 5 * 60

    init(repository: TransactionRepository, bank: BankService, sync: TransactionSyncService,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.bank = bank
        self.sync = sync
        self.calendar = calendar
        self.now = now
    }

    /// Shows cached data immediately, then refreshes if it is stale.
    func onAppear() async {
        reloadFromCache()
        let isStale = lastUpdated.map { now().timeIntervalSince($0) > Self.staleAfter } ?? true
        if hasConnection && isStale {
            await refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let outcome = await sync.sync(now: now())
        if let failure = outcome.failures.first {
            error = UserFacingError(failure.error)
        } else if let storageError = outcome.storageError {
            error = UserFacingError(title: "Couldn't save transactions", message: storageError.localizedDescription, action: .retry)
        } else {
            error = nil
        }
        reloadFromCache()
    }

    func reloadFromCache() {
        hasConnection = !bank.connections().isEmpty
        let today = SpendingCalculator.transactions(repository.transactions(on: now(), calendar: calendar), on: now(), calendar: calendar)
        transactions = today
        totalSpentMinor = SpendingCalculator.netSpendMinor(today)
        lastUpdated = sync.lastSuccessfulSync ?? repository.latestUpdate()
    }
}
