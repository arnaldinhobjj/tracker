import AccountKit
import Foundation
import Networking
import Observation
import SharedModels

/// The merge rules for cloud sync, kept pure so they can be unit tested.
enum CloudMerge {
    /// A local row needs pushing when it changed after it last matched the cloud (or never did).
    static func isDirty(updatedAt: Date?, syncedAt: Date?) -> Bool {
        guard let syncedAt else { return true }
        guard let updatedAt else { return false }
        return updatedAt > syncedAt
    }

    /// Whether a pulled row should replace the local one. Untouched local rows always take the
    /// server's version; when both changed, the later write wins (ties go to the server, whose
    /// clock is the reference). A remote row without a timestamp never overwrites a local edit.
    static func shouldApplyRemote(remoteUpdatedAt: Date?, localUpdatedAt: Date?, localSyncedAt: Date?, localExists: Bool) -> Bool {
        guard localExists else { return true }
        guard isDirty(updatedAt: localUpdatedAt, syncedAt: localSyncedAt) else { return true }
        guard let remoteUpdatedAt else { return false }
        guard let localUpdatedAt else { return true }
        return remoteUpdatedAt >= localUpdatedAt
    }

    enum SettingsAction: Equatable {
        case push
        case applyRemote
        case none
    }

    /// One settings row per user: push local edits unless the server has a later one.
    static func settingsAction(localChangedAt: Date?, lastPushedAt: Date?, remoteUpdatedAt: Date?,
                               remoteExists: Bool, remoteDiffers: Bool) -> SettingsAction {
        let localDirty = localChangedAt != nil && isDirty(updatedAt: localChangedAt, syncedAt: lastPushedAt)
        guard remoteExists else { return localDirty || lastPushedAt == nil ? .push : .none }
        if localDirty {
            if let remoteUpdatedAt, let localChangedAt, remoteUpdatedAt > localChangedAt, remoteDiffers {
                return .applyRemote
            }
            return remoteDiffers ? .push : .none
        }
        return remoteDiffers ? .applyRemote : .none
    }
}

/// Keeps this device's transactions, visits and settings in step with the user's account
/// (docs/backend-contract.md, "Sync"): pull changes since a per-table cursor, then push local
/// changes. Reading needs a signed-in account; pushing needs an active subscription.
@MainActor
@Observable
final class CloudSyncService {
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    var error: UserFacingError?

    @ObservationIgnored private let rest: SupabaseRESTClient?
    @ObservationIgnored private let transactions: TransactionRepository
    @ObservationIgnored private let visits: VisitRepository
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var inFlightUserID: UUID?

    /// The signed-in user, or nil (signed out, developer account, UI tests).
    @ObservationIgnored var currentUserID: @MainActor () -> UUID? = { nil }
    /// Whether the user may write (trial, active or grace period).
    @ObservationIgnored var canWrite: @MainActor () -> Bool = { false }
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?
    /// Pulled rows changed local data: refresh what's on screen.
    @ObservationIgnored var onDataChanged: (@MainActor () -> Void)?

    static let transactionsTable = "transactions"
    static let visitsTable = "visits"
    static let settingsTable = "user_settings"
    private static let tombstonesKey = "cloud.pendingDeletes.transactions"
    private static let lastUserKey = "cloud.lastUserID"
    private static let maxTombstones = 2_000

    init(rest: SupabaseRESTClient?, transactions: TransactionRepository, visits: VisitRepository, settings: AppSettings, defaults: UserDefaults) {
        self.rest = rest
        self.transactions = transactions
        self.visits = visits
        self.settings = settings
        self.defaults = defaults
        transactions.onDeleted = { [weak self] removed in
            self?.recordDeleted(removed)
        }
    }

    /// Runs a sync, or joins the one already running. Does nothing when signed out.
    func sync(now: Date = Date()) async {
        guard rest != nil, let userID = currentUserID() else { return }
        if let inFlight, inFlightUserID == userID { return await inFlight.value }
        // A run for another account must never apply its results to this one.
        cancelInFlight()
        let task = Task { await perform(userID: userID, now: now) }
        inFlight = task
        inFlightUserID = userID
        await task.value
        if inFlightUserID == userID, inFlight == task {
            inFlight = nil
            inFlightUserID = nil
        }
    }

    /// Stops a running sync (sign-out or account switch): anything it fetches afterwards is dropped.
    func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
        inFlightUserID = nil
    }

    /// Throws when this run was cancelled or the signed-in account changed while awaiting the network.
    private func ensureCurrent(_ userID: UUID) throws {
        if Task.isCancelled || currentUserID() != userID { throw CancellationError() }
    }

    private func perform(userID: UUID, now: Date) async {
        guard let rest else { return }
        isSyncing = true
        defer { isSyncing = false }
        prepare(for: userID)
        var changed = false
        do {
            // Pull first, so a newer edit from another device isn't overwritten by this one.
            changed = try await pullTransactions(userID: userID, rest: rest, now: now) || changed
            changed = try await pullVisits(userID: userID, rest: rest, now: now) || changed
            let canWrite = self.canWrite()
            changed = try await syncSettings(userID: userID, rest: rest, canWrite: canWrite, now: now) || changed
            // Deletions are pushed even without a subscription: lapsed users may still delete.
            try await pushDeletions(userID: userID, rest: rest, softDelete: canWrite)
            if canWrite {
                try await pushTransactions(userID: userID, rest: rest)
                try await pushVisits(userID: userID, rest: rest)
            }
            lastSync = now
            error = nil
        } catch is CancellationError {
            return
        } catch AuthError.sessionExpired {
            onSessionExpired?()
        } catch let networkError as NetworkError where networkError == .offline || networkError == .timedOut {
            // Try again at the next sync point; local data is intact.
        } catch {
            self.error = UserFacingError(error)
        }
        if changed { onDataChanged?() }
    }

    /// A different account on this device: everything here is new to it.
    private func prepare(for userID: UUID) {
        let id = userID.uuidString
        guard defaults.string(forKey: Self.lastUserKey) != id else { return }
        if defaults.string(forKey: Self.lastUserKey) != nil {
            transactions.resetCloudSyncState()
            visits.resetCloudSyncState()
            defaults.removeObject(forKey: settingsPushedKey(userID))
        }
        defaults.set(id, forKey: Self.lastUserKey)
    }

    // MARK: Transactions

    private func pullTransactions(userID: UUID, rest: SupabaseRESTClient, now: Date) async throws -> Bool {
        let result = try await rest.fetchChanges(TransactionSyncRow.self, from: Self.transactionsTable, after: cursor(Self.transactionsTable, userID))
        try ensureCurrent(userID)
        let pending = Set(pendingTombstones().map(\.id))
        let changed = try transactions.applyRemote(result.rows, pendingDeletionIDs: pending, now: now)
        saveCursor(result.cursor, table: Self.transactionsTable, userID: userID)
        return changed
    }

    /// Local deletions. With a subscription they are soft (`deleted_at`, so other devices learn
    /// about them); without one RLS forbids updates, so the rows are hard-deleted instead.
    private func pushDeletions(userID: UUID, rest: SupabaseRESTClient, softDelete: Bool) async throws {
        let tombstones = pendingTombstones()
        guard !tombstones.isEmpty else { return }
        // Skip any id that is back locally (a pending item re-fetched unchanged).
        let stillPresent = transactions.existingIDs(in: tombstones.map(\.id))
        let deletes = tombstones.filter { !stillPresent.contains($0.id) }.map { row -> TransactionSyncRow in
            var row = row
            row.userID = userID
            return row
        }
        if !deletes.isEmpty {
            if softDelete {
                try await rest.upsert(deletes, into: Self.transactionsTable, onConflict: "user_id,id")
            } else {
                try await rest.delete(from: Self.transactionsTable, userID: userID, ids: deletes.map(\.id))
            }
        }
        clearTombstones(Set(tombstones.map(\.id)))
    }

    private func pushTransactions(userID: UUID, rest: SupabaseRESTClient) async throws {
        let startedAt = Date()
        let dirty = transactions.cloudDirty()
        guard !dirty.isEmpty else { return }
        let rows = dirty.map { TransactionSyncRow(stored: $0.domain, userID: userID) }
        try await rest.upsert(rows, into: Self.transactionsTable, onConflict: "user_id,id")
        try ensureCurrent(userID)
        transactions.markCloudSynced(ids: Set(rows.map(\.id)), at: startedAt)
    }

    private func recordDeleted(_ removed: [BankTransaction]) {
        guard !removed.isEmpty else { return }
        let deletedAt = Date()
        var rows = pendingTombstones()
        let placeholder = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        rows.append(contentsOf: removed.map { TransactionSyncRow(stored: $0, userID: placeholder, deletedAt: deletedAt) })
        if rows.count > Self.maxTombstones { rows.removeFirst(rows.count - Self.maxTombstones) }
        if let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: Self.tombstonesKey)
        }
    }

    private func pendingTombstones() -> [TransactionSyncRow] {
        guard let data = defaults.data(forKey: Self.tombstonesKey) else { return [] }
        return (try? JSONDecoder().decode([TransactionSyncRow].self, from: data)) ?? []
    }

    private func clearTombstones(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = pendingTombstones().filter { !ids.contains($0.id) }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.tombstonesKey)
        } else if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: Self.tombstonesKey)
        }
    }

    // MARK: Visits

    private func pullVisits(userID: UUID, rest: SupabaseRESTClient, now: Date) async throws -> Bool {
        let result = try await rest.fetchChanges(VisitSyncRow.self, from: Self.visitsTable, after: cursor(Self.visitsTable, userID))
        try ensureCurrent(userID)
        let changed = try visits.applyRemote(result.rows, now: now)
        saveCursor(result.cursor, table: Self.visitsTable, userID: userID)
        return changed
    }

    private func pushVisits(userID: UUID, rest: SupabaseRESTClient) async throws {
        let startedAt = Date()
        let dirty = visits.cloudDirty()
        guard !dirty.isEmpty else { return }
        let rows = dirty.map { VisitSyncRow(stored: $0, userID: userID) }
        try await rest.upsert(rows, into: Self.visitsTable, onConflict: "user_id,id")
        try ensureCurrent(userID)
        visits.markCloudSynced(ids: Set(rows.map(\.id)), at: startedAt)
    }

    // MARK: Settings

    private func settingsPushedKey(_ userID: UUID) -> String { "cloud.settingsPushedAt.\(userID.uuidString)" }

    private func syncSettings(userID: UUID, rest: SupabaseRESTClient, canWrite: Bool, now: Date) async throws -> Bool {
        let remote = try await rest.fetchPage(UserSettingsSyncRow.self, from: Self.settingsTable, after: nil, hasIDColumn: false, limit: 1).first
        try ensureCurrent(userID)
        let local = settings.synced
        let action = CloudMerge.settingsAction(
            localChangedAt: settings.changedAt,
            lastPushedAt: defaults.object(forKey: settingsPushedKey(userID)) as? Date,
            remoteUpdatedAt: remote?.updatedAt.flatMap(ISO8601.date(from:)),
            remoteExists: remote != nil,
            remoteDiffers: remote.map { $0.settings != local } ?? true
        )
        switch action {
        case .applyRemote:
            guard let remote else { return false }
            settings.applyRemote(remote.settings)
            defaults.set(now, forKey: settingsPushedKey(userID))
            return true
        case .push:
            guard canWrite else { return false }
            try await rest.upsert([UserSettingsSyncRow(userID: userID, settings: local)], into: Self.settingsTable, onConflict: "user_id")
            defaults.set(now, forKey: settingsPushedKey(userID))
            return false
        case .none:
            return false
        }
    }

    // MARK: Cursors (per user and table)

    private func cursorKey(_ table: String, _ userID: UUID) -> String { "cloud.cursor.\(userID.uuidString).\(table)" }

    private func cursor(_ table: String, _ userID: UUID) -> SyncCursor? {
        guard let data = defaults.data(forKey: cursorKey(table, userID)) else { return nil }
        return try? JSONDecoder().decode(SyncCursor.self, from: data)
    }

    private func saveCursor(_ cursor: SyncCursor?, table: String, userID: UUID) {
        guard let cursor, let data = try? JSONEncoder().encode(cursor) else { return }
        defaults.set(data, forKey: cursorKey(table, userID))
    }
}

// MARK: - Row mapping

extension TransactionSyncRow {
    init(stored transaction: BankTransaction, userID: UUID, deletedAt: Date? = nil) {
        self.init(userID: userID, id: transaction.id, accountID: transaction.accountID, merchant: transaction.merchant,
                  rawDescription: transaction.rawDescription, amountMinor: transaction.amountMinor, currency: transaction.currency,
                  direction: transaction.direction.rawValue, bankCategory: transaction.bankCategory, category: transaction.category.rawValue,
                  occurredAt: transaction.timestamp, hasTime: transaction.hasTime, isPending: transaction.isPending, deletedAt: deletedAt)
    }

    var bankTransaction: BankTransaction {
        BankTransaction(id: id, accountID: accountID, merchant: merchant, rawDescription: rawDescription, amountMinor: amountMinor,
                        currency: currency, direction: TransactionDirection(rawValue: direction) ?? .debit, bankCategory: bankCategory,
                        category: SpendCategory(rawValue: category) ?? .other, timestamp: occurredAt, hasTime: hasTime, isPending: isPending)
    }
}

extension VisitSyncRow {
    init(stored visit: StoredVisit, userID: UUID) {
        self.init(userID: userID, id: visit.id, arrival: visit.arrival, departure: visit.departure, latitude: visit.latitude,
                  longitude: visit.longitude, placeName: visit.placeName, placeCategory: visit.placeCategory,
                  isNamedPlace: visit.isNamedPlace, isResolved: visit.isResolved, calendarEventID: visit.calendarEventID,
                  calendarContentHash: visit.calendarContentHash, calendarSyncedAt: visit.calendarSyncedAt)
    }
}
