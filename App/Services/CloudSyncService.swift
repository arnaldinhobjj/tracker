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
///
/// Transactions and visits are end-to-end encrypted with the account's sync key (iCloud Keychain;
/// see `SyncKeyManager`): the server only ever stores ciphertext. Visits are only uploaded when the
/// user turns on visit sync. Settings are plain preferences and stay readable.
@MainActor
@Observable
final class CloudSyncService {
    enum EncryptionStatus: Equatable {
        /// Not checked yet (or signed out).
        case unknown
        case ready
        /// The account's data is encrypted with a key that hasn't reached this device: iCloud
        /// Keychain is off or still syncing. The user can wait or start over from this device.
        case waitingForKey
    }

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var encryptionStatus = EncryptionStatus.unknown
    /// Visits uploaded by an older app version (before encryption and before visit sync was
    /// opt-in) are still in the account. Until the user decides, they are neither re-uploaded nor
    /// deleted.
    private(set) var hasLegacyVisitsInCloud = false
    var error: UserFacingError?

    @ObservationIgnored private let rest: SupabaseRESTClient?
    @ObservationIgnored private let keys: SyncKeyManager
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

    static let transactionsTable = TransactionSyncRow.table
    static let visitsTable = VisitSyncRow.table
    static let settingsTable = "user_settings"
    /// Where earlier versions kept pending deletions (now in SwiftData): Sprint 1 …
    private static let legacyTombstonesV2Key = "cloud.pendingDeletes.v2"
    /// … and, before encryption, as plaintext sync rows.
    private static let legacyTombstonesKey = "cloud.pendingDeletes.transactions"
    private static let lastUserKey = "cloud.lastUserID"

    init(rest: SupabaseRESTClient?, keys: SyncKeyManager, transactions: TransactionRepository, visits: VisitRepository,
         settings: AppSettings, defaults: UserDefaults) {
        self.rest = rest
        self.keys = keys
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
        defer { if changed { onDataChanged?() } }
        do {
            let canWrite = self.canWrite()
            // Settings first: they decide whether visits are uploaded.
            changed = try await syncSettings(userID: userID, rest: rest, canWrite: canWrite, now: now) || changed

            let resolution = try await keys.resolve(userID: userID, rest: rest)
            try ensureCurrent(userID)
            guard case .ready(let key) = resolution else {
                encryptionStatus = .waitingForKey
                error = nil
                return
            }
            encryptionStatus = .ready
            adopt(key, userID: userID)

            // Pull before pushing, so a newer edit from another device isn't overwritten by this one.
            changed = try await pullTransactions(userID: userID, rest: rest, key: key, now: now) || changed
            changed = try await pullVisits(userID: userID, rest: rest, key: key, now: now) || changed
            // Deletions are pushed even without a subscription: lapsed users may still delete.
            try await pushDeletions(userID: userID, rest: rest, key: key, softDelete: canWrite)
            if canWrite {
                try await pushTransactions(userID: userID, rest: rest, key: key)
                if settings.visitSyncEnabled {
                    try await pushVisits(userID: userID, rest: rest, key: key)
                    // Any legacy visits were re-uploaded encrypted along with the rest.
                    setLegacyVisits(false, userID: userID)
                }
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
    }

    /// A different account on this device: everything here is new to it.
    private func prepare(for userID: UUID) {
        let id = userID.uuidString
        hasLegacyVisitsInCloud = defaults.bool(forKey: legacyVisitsKey(userID))
        guard defaults.string(forKey: Self.lastUserKey) != id else { return }
        if defaults.string(forKey: Self.lastUserKey) != nil {
            transactions.resetCloudSyncState()
            visits.resetCloudSyncState()
            defaults.removeObject(forKey: settingsPushedKey(userID))
        }
        defaults.set(id, forKey: Self.lastUserKey)
    }

    // MARK: Encryption key

    private func keyIDKey(_ userID: UUID) -> String { "cloud.keyID.\(userID.uuidString)" }

    /// The first encrypted sync on this device (an upgrade from a version without encryption), or
    /// the account's key changed (another device started over): read everything again, so legacy
    /// plaintext rows and rows under the old key are found and re-uploaded with this key.
    private func adopt(_ key: SyncKey, userID: UUID) {
        let previous = defaults.string(forKey: keyIDKey(userID))
        guard previous != key.id else { return }
        clearCursors(userID)
        if previous != nil {
            // The cloud copy was replaced: everything here must be uploaded again.
            transactions.resetCloudSyncState()
            visits.resetCloudSyncState()
        }
        // Recorded now, not after the sync succeeds: an interrupted re-read then resumes from its
        // saved cursor instead of starting from the beginning again.
        defaults.set(key.id, forKey: keyIDKey(userID))
    }

    /// "Start over": for when the key can't be recovered (iCloud Keychain lost or off). Deletes
    /// the account's encrypted transactions and visits and its key registration, then uploads
    /// this device's data with a new key. Data only on other devices stays there and is uploaded
    /// again from those devices once they have the new key.
    func startEncryptionOver() async throws {
        guard let rest, let userID = currentUserID() else { return }
        cancelInFlight()
        try await rest.deleteAll(from: Self.transactionsTable, userID: userID)
        try await rest.deleteAll(from: Self.visitsTable, userID: userID)
        try await rest.deleteSyncKey(userID: userID)
        transactions.resetCloudSyncState()
        visits.resetCloudSyncState()
        clearCursors(userID)
        defaults.removeObject(forKey: keyIDKey(userID))
        clearTombstones(Set(pendingTombstones().map(\.transaction.id)))
        setLegacyVisits(false, userID: userID)
        encryptionStatus = .unknown
        await sync()
    }

    // MARK: Transactions

    private func pullTransactions(userID: UUID, rest: SupabaseRESTClient, key: SyncKey, now: Date) async throws -> Bool {
        var changed = false
        // Each page is applied and its cursor saved before the next is fetched, so an interrupted
        // first sync (a year of data) resumes where it stopped instead of starting again.
        try await rest.forEachChangePage(TransactionSyncRow.self, from: Self.transactionsTable,
                                         after: cursor(Self.transactionsTable, userID)) { rows, pageCursor in
            try ensureCurrent(userID)
            let readable = Self.readable(rows, open: { try $0.opening(with: key) }, isDeletion: { $0.deletedAt != nil })
            // Plaintext tombstones from older versions: queue an encrypted tombstone, which
            // overwrites (or, without a subscription, hard-deletes) the plaintext on the server.
            let legacyDeleted = readable.filter { $0.isLegacyPlaintext && $0.deletedAt != nil }.compactMap(\.bankTransaction)
            let pending = Set(pendingTombstones().map(\.transaction.id))
            changed = try transactions.applyRemote(readable, pendingDeletionIDs: pending, now: now) || changed
            recordDeleted(legacyDeleted)
            saveCursor(pageCursor, table: Self.transactionsTable, userID: userID)
        }
        return changed
    }

    /// Rows this device can read. Rows sealed with another key, or damaged, are skipped; their
    /// deletions still apply, because removing a row needs only its id.
    private static func readable<Row: SyncRow>(_ rows: [Row], open: (Row) throws -> Row, isDeletion: (Row) -> Bool) -> [Row] {
        rows.compactMap { row in
            if let opened = try? open(row) { return opened }
            return isDeletion(row) ? row : nil
        }
    }

    /// Local deletions. With a subscription they are soft (`deleted_at`, so other devices learn
    /// about them); without one RLS forbids updates, so the rows are hard-deleted instead.
    private func pushDeletions(userID: UUID, rest: SupabaseRESTClient, key: SyncKey, softDelete: Bool) async throws {
        let tombstones = pendingTombstones()
        guard !tombstones.isEmpty else { return }
        // Skip any id that is back locally (a pending item re-fetched unchanged).
        let stillPresent = transactions.existingIDs(in: tombstones.map(\.transaction.id))
        let deletes = tombstones.filter { !stillPresent.contains($0.transaction.id) }
        if !deletes.isEmpty {
            if softDelete {
                let rows = try deletes.map {
                    try TransactionSyncRow(stored: $0.transaction, userID: userID, deletedAt: $0.deletedAt).sealing(with: key)
                }
                try await rest.upsert(rows, into: Self.transactionsTable, onConflict: "user_id,id")
            } else {
                try await rest.delete(from: Self.transactionsTable, userID: userID, ids: deletes.map(\.transaction.id))
            }
        }
        clearTombstones(Set(tombstones.map(\.transaction.id)))
    }

    private func pushTransactions(userID: UUID, rest: SupabaseRESTClient, key: SyncKey) async throws {
        let startedAt = Date()
        let dirty = transactions.cloudDirty()
        guard !dirty.isEmpty else { return }
        let rows = try dirty.map { try TransactionSyncRow(stored: $0.domain, userID: userID).sealing(with: key) }
        try await rest.upsert(rows, into: Self.transactionsTable, onConflict: "user_id,id")
        try ensureCurrent(userID)
        transactions.markCloudSynced(ids: Set(rows.map(\.id)), at: startedAt)
    }

    /// A transaction removed on this device whose deletion hasn't reached the account yet.
    struct PendingDeletion: Equatable {
        var transaction: BankTransaction
        var deletedAt: Date
    }

    private func recordDeleted(_ removed: [BankTransaction]) {
        transactions.addPendingDeletions(removed)
    }

    /// Oldest first. Stored in SwiftData; deletions queued by earlier versions in UserDefaults are
    /// moved over the first time.
    func pendingTombstones() -> [PendingDeletion] {
        migrateLegacyTombstones()
        return transactions.pendingDeletions().map { PendingDeletion(transaction: $0.transaction, deletedAt: $0.deletedAt) }
    }

    private func clearTombstones(_ ids: Set<String>) {
        transactions.removePendingDeletions(ids: ids)
    }

    /// Sprint 1 kept pending deletions as JSON in UserDefaults (`v2`: `PendingDeletion`s; before
    /// that, plaintext sync rows). Moved into SwiftData once, then removed from UserDefaults.
    private func migrateLegacyTombstones() {
        struct LegacyPendingDeletion: Decodable {
            var transaction: BankTransaction
            var deletedAt: Date
        }
        var moved: [(BankTransaction, Date)] = []
        if let data = defaults.data(forKey: Self.legacyTombstonesV2Key) {
            let rows = (try? JSONDecoder().decode([LegacyPendingDeletion].self, from: data)) ?? []
            moved += rows.map { ($0.transaction, $0.deletedAt) }
            defaults.removeObject(forKey: Self.legacyTombstonesV2Key)
        }
        if let data = defaults.data(forKey: Self.legacyTombstonesKey) {
            let rows = (try? JSONDecoder().decode([TransactionSyncRow].self, from: data)) ?? []
            moved += rows.compactMap { row in row.bankTransaction.map { ($0, row.deletedAt ?? Date()) } }
            defaults.removeObject(forKey: Self.legacyTombstonesKey)
        }
        for (transaction, deletedAt) in moved {
            transactions.addPendingDeletions([transaction], at: deletedAt)
        }
    }

    // MARK: Visits

    private func legacyVisitsKey(_ userID: UUID) -> String { "cloud.legacyVisits.\(userID.uuidString)" }

    private func setLegacyVisits(_ present: Bool, userID: UUID) {
        if present {
            defaults.set(true, forKey: legacyVisitsKey(userID))
        } else {
            defaults.removeObject(forKey: legacyVisitsKey(userID))
        }
        hasLegacyVisitsInCloud = present
    }

    private func pullVisits(userID: UUID, rest: SupabaseRESTClient, key: SyncKey, now: Date) async throws -> Bool {
        var changed = false
        try await rest.forEachChangePage(VisitSyncRow.self, from: Self.visitsTable, after: cursor(Self.visitsTable, userID)) { rows, pageCursor in
            try ensureCurrent(userID)
            let readable = Self.readable(rows, open: { try $0.opening(with: key) }, isDeletion: { $0.deletedAt != nil })
            changed = try visits.applyRemote(readable, now: now) || changed
            if readable.contains(where: { $0.isLegacyPlaintext && $0.deletedAt == nil }) {
                setLegacyVisits(true, userID: userID)
            }
            saveCursor(pageCursor, table: Self.visitsTable, userID: userID)
        }
        return changed
    }

    /// Only called with visit sync on.
    private func pushVisits(userID: UUID, rest: SupabaseRESTClient, key: SyncKey) async throws {
        let startedAt = Date()
        let dirty = visits.cloudDirty()
        guard !dirty.isEmpty else { return }
        let rows = try dirty.map { try VisitSyncRow(stored: $0, userID: userID).sealing(with: key) }
        try await rest.upsert(rows, into: Self.visitsTable, onConflict: "user_id,id")
        try ensureCurrent(userID)
        visits.markCloudSynced(ids: Set(rows.map(\.id)), at: startedAt)
    }

    /// Turns visit sync on (the user chose to keep their visits in the account) and uploads them,
    /// encrypted, replacing any plaintext copies from older versions.
    func enableVisitSync() async {
        settings.visitSyncEnabled = true
        await sync()
    }

    /// Turns visit sync off and deletes every visit from the account. Visits on this iPhone stay.
    /// Allowed without a subscription.
    func disableVisitSyncAndRemoveFromCloud() async throws {
        settings.visitSyncEnabled = false
        guard let rest, let userID = currentUserID() else { return }
        try await rest.deleteAll(from: Self.visitsTable, userID: userID)
        visits.resetCloudSyncState()
        setLegacyVisits(false, userID: userID)
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

    private func clearCursors(_ userID: UUID) {
        defaults.removeObject(forKey: cursorKey(Self.transactionsTable, userID))
        defaults.removeObject(forKey: cursorKey(Self.visitsTable, userID))
    }
}

// MARK: - Row mapping

extension TransactionSyncRow {
    init(stored transaction: BankTransaction, userID: UUID, deletedAt: Date? = nil) {
        self.init(userID: userID, id: transaction.id, content: TransactionSyncContent(
            accountID: transaction.accountID, merchant: transaction.merchant, rawDescription: transaction.rawDescription,
            amountMinor: transaction.amountMinor, currency: transaction.currency, direction: transaction.direction.rawValue,
            bankCategory: transaction.bankCategory, category: transaction.category.rawValue, occurredAt: transaction.timestamp,
            hasTime: transaction.hasTime, isPending: transaction.isPending
        ), deletedAt: deletedAt)
    }

    /// Nil while the row is still encrypted.
    var bankTransaction: BankTransaction? {
        guard let content else { return nil }
        return BankTransaction(id: id, accountID: content.accountID, merchant: content.merchant, rawDescription: content.rawDescription,
                               amountMinor: content.amountMinor, currency: content.currency,
                               direction: TransactionDirection(rawValue: content.direction) ?? .debit, bankCategory: content.bankCategory,
                               category: SpendCategory(rawValue: content.category) ?? .other, timestamp: content.occurredAt,
                               hasTime: content.hasTime, isPending: content.isPending)
    }
}

extension VisitSyncRow {
    init(stored visit: StoredVisit, userID: UUID) {
        self.init(userID: userID, id: visit.id, content: VisitSyncContent(
            arrival: visit.arrival, departure: visit.departure, latitude: visit.latitude, longitude: visit.longitude,
            placeName: visit.placeName, placeCategory: visit.placeCategory, isNamedPlace: visit.isNamedPlace,
            isResolved: visit.isResolved
        ))
    }
}
