import Foundation
import SharedModels
import SwiftData

/// Reads and writes cached transactions. Runs on the main actor with the main context;
/// the data set (weeks of transactions) is small enough for that.
@MainActor
final class TransactionRepository {
    // Keep the container alive: a ModelContext does not retain it.
    private let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    func transactions(from start: Date, to end: Date) -> [BankTransaction] {
        let descriptor = FetchDescriptor<StoredTransaction>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.domain)
    }

    func transactions(on day: Date, calendar: Calendar = .current) -> [BankTransaction] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return transactions(from: start, to: end)
    }

    func latestUpdate() -> Date? {
        var descriptor = FetchDescriptor<StoredTransaction>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.updatedAt
    }

    /// Upserts fetched transactions. Pending transactions for refreshed accounts are replaced
    /// wholesale, because banks drop a pending item (and issue a new ID) when it settles.
    func apply(_ fetched: [BankTransaction], refreshedAccountIDs: Set<String>, now: Date = Date()) throws {
        if !refreshedAccountIDs.isEmpty {
            let accountIDs = Array(refreshedAccountIDs)
            let stalePending = FetchDescriptor<StoredTransaction>(
                predicate: #Predicate { $0.isPending && accountIDs.contains($0.accountID) }
            )
            for item in try context.fetch(stalePending) {
                context.delete(item)
            }
            try context.save()
        }

        let ids = fetched.map(\.id)
        let existing = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { ids.contains($0.id) }))
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for transaction in fetched {
            if let stored = byID[transaction.id] {
                stored.update(from: transaction, at: now)
            } else {
                let stored = StoredTransaction(transaction, updatedAt: now)
                context.insert(stored)
                byID[transaction.id] = stored
            }
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: StoredTransaction.self)
        try context.save()
    }
}
