import AccountKit
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

    /// Called with transactions this device removed (pending ones replaced when they settle),
    /// so cloud sync can delete them from the account too.
    var onDeleted: (@MainActor ([BankTransaction]) -> Void)?

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
            var removed: [BankTransaction] = []
            for item in try context.fetch(stalePending) {
                removed.append(item.domain)
                context.delete(item)
            }
            try context.save()
            if !removed.isEmpty { onDeleted?(removed) }
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

    // MARK: Cloud sync

    func allStored() -> [StoredTransaction] {
        (try? context.fetch(FetchDescriptor<StoredTransaction>())) ?? []
    }

    /// Transactions changed since they were last pushed or pulled.
    func cloudDirty() -> [StoredTransaction] {
        allStored().filter { CloudMerge.isDirty(updatedAt: $0.updatedAt, syncedAt: $0.cloudSyncedAt) }
    }

    func existingIDs(in ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let found = (try? context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return Set(found.map(\.id))
    }

    func markCloudSynced(ids: Set<String>, at date: Date) {
        for item in allStored() where ids.contains(item.id) {
            item.cloudSyncedAt = date
        }
        try? context.save()
    }

    /// Applies pulled, decrypted rows (last write wins by server time; soft-deleted rows are
    /// removed). Returns true if anything changed.
    /// `pendingDeletionIDs`: rows deleted on this device whose deletion hasn't reached the server
    /// yet. A pulled (older) copy of one must not bring it back.
    @discardableResult
    func applyRemote(_ rows: [TransactionSyncRow], pendingDeletionIDs: Set<String> = [], now: Date = Date()) throws -> Bool {
        guard !rows.isEmpty else { return false }
        let ids = rows.map(\.id)
        let existing = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { ids.contains($0.id) }))
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for row in rows {
            let local = byID[row.id]
            let remoteUpdated = row.updatedAt.flatMap(ISO8601.date(from:))
            guard CloudMerge.shouldApplyRemote(remoteUpdatedAt: remoteUpdated, localUpdatedAt: local?.updatedAt,
                                               localSyncedAt: local?.cloudSyncedAt, localExists: local != nil) else { continue }
            if row.deletedAt != nil {
                if let local {
                    context.delete(local)
                    byID[row.id] = nil
                    changed = true
                }
                continue
            }
            if local == nil && pendingDeletionIDs.contains(row.id) { continue }
            // Still encrypted (sealed with a key this device lacks): nothing to apply.
            guard let transaction = row.bankTransaction else { continue }
            // A plaintext row from an older app version stays "not synced", so it is uploaded
            // again encrypted, which erases the plaintext copy on the server.
            let syncedAt: Date? = row.isLegacyPlaintext ? nil : now
            if let local {
                local.update(from: transaction, at: now)
                local.cloudSyncedAt = syncedAt
            } else {
                let stored = StoredTransaction(transaction, updatedAt: now)
                stored.cloudSyncedAt = syncedAt
                context.insert(stored)
                byID[row.id] = stored
            }
            changed = true
        }
        try context.save()
        return changed
    }

    /// Marks every transaction as not synced (another account signed in on this device).
    func resetCloudSyncState() {
        for item in allStored() { item.cloudSyncedAt = nil }
        try? context.save()
    }
}
