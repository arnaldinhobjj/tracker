import BankKit
import LocationKit
import SharedModels
import SwiftData
import XCTest
@testable import DayLedger

/// The store on users' devices must open (and migrate) with every new version, and an unreadable
/// store must never brick the app or silently lose the old file.
@MainActor
final class PersistenceMigrationTests: XCTestCase {
    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("DayLedger.store")
    }

    private func v1Transaction(_ id: String, updatedAt: TimeInterval, syncedAt: TimeInterval?) -> SchemaV1.StoredTransaction {
        SchemaV1.StoredTransaction(id: id, accountID: "a", merchant: "Tesco", rawDescription: "TESCO", amountMinor: 1_287, currency: "GBP",
                                   directionRaw: "debit", bankCategory: "PURCHASE", categoryRaw: "groceries", timestamp: Date(),
                                   hasTime: true, isPending: false, updatedAt: Date(timeIntervalSince1970: updatedAt),
                                   cloudSyncedAt: syncedAt.map(Date.init(timeIntervalSince1970:)))
    }

    func testAStoreWrittenByVersion1MigratesKeepingDataAndUploadState() throws {
        let url = try makeStoreURL()
        do {
            let v1 = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: v1, configurations: ModelConfiguration(schema: v1, url: url))
            let context = ModelContext(container)
            context.insert(v1Transaction("clean", updatedAt: 1_000, syncedAt: 2_000))
            context.insert(v1Transaction("edited", updatedAt: 3_000, syncedAt: 2_000))
            context.insert(v1Transaction("never", updatedAt: 1_000, syncedAt: nil))
            context.insert(SchemaV1.StoredVisit(id: "v-clean", arrival: Date(), departure: nil, latitude: 51.5, longitude: -0.1,
                                                isNamedPlace: true, isResolved: true, updatedAt: Date(timeIntervalSince1970: 1_000),
                                                cloudSyncedAt: Date(timeIntervalSince1970: 2_000)))
            context.insert(SchemaV1.StoredVisit(id: "v-new", arrival: Date(), departure: nil, latitude: 51.5, longitude: -0.1,
                                                isNamedPlace: false, isResolved: false, updatedAt: Date(), cloudSyncedAt: nil))
            try context.save()
        }

        let (container, result) = PersistenceController.open(at: url)

        XCTAssertEqual(result, .opened)
        let transactions = TransactionRepository(container: container)
        XCTAssertEqual(transactions.allStored().count, 3, "No data lost")
        XCTAssertEqual(Set(transactions.cloudDirty().map(\.id)), ["edited", "never"], "Upload state carried over")
        let visits = VisitRepository(container: container)
        XCTAssertEqual(visits.allVisits().count, 2)
        XCTAssertEqual(visits.cloudDirty().map(\.id), ["v-new"])
        XCTAssertTrue(transactions.pendingDeletions().isEmpty, "The new entity exists and is empty")
    }

    func testAnUnreadableStoreIsMovedAsideAndReplaced() throws {
        let url = try makeStoreURL()
        let garbage = Data("not a database".utf8)
        try garbage.write(to: url)

        let (container, result) = PersistenceController.open(at: url)

        guard case .recreated(let movedTo) = result else { return XCTFail("Expected a new store, got \(result)") }
        XCTAssertEqual(try Data(contentsOf: movedTo), garbage, "The old file is kept, not deleted")
        let repository = TransactionRepository(container: container)
        try repository.apply(MockBankService.sampleTransactions(for: Date()), refreshedAccountIDs: [])
        XCTAssertFalse(repository.allStored().isEmpty, "The new store works")
    }

    func testRecreatingTheStoreResetsSyncBookkeepingOnly() {
        let defaults = UserDefaults(suiteName: "persistence.\(UUID().uuidString)")!
        defaults.set(Data(), forKey: "cloud.cursor.user.transactions")
        defaults.set("abc", forKey: "cloud.keyID.user")
        defaults.set(Date(), forKey: "bank.lastSuccessfulSync")
        defaults.set(true, forKey: "settings.locationLogging")

        PersistenceController.resetSyncBookkeeping(defaults)

        XCTAssertNil(defaults.object(forKey: "cloud.cursor.user.transactions"))
        XCTAssertNil(defaults.object(forKey: "cloud.keyID.user"))
        XCTAssertNil(defaults.object(forKey: "bank.lastSuccessfulSync"))
        XCTAssertEqual(defaults.object(forKey: "settings.locationLogging") as? Bool, true, "Preferences are kept")
    }
}

/// The upload flag replaces comparing dates on every row of every sync.
@MainActor
final class CloudDirtyFlagTests: XCTestCase {
    private func transaction(_ id: String) -> BankTransaction {
        BankTransaction(id: id, accountID: "a", merchant: "Costa", rawDescription: "COSTA", amountMinor: 340, direction: .debit,
                        bankCategory: "PURCHASE", category: .coffee, timestamp: Date(), hasTime: true, isPending: false)
    }

    func testEditsDuringAnUploadStayMarked() throws {
        let repository = TransactionRepository(container: PersistenceController.makeContainer(appGroupID: "", inMemory: true))
        let before = Date()
        try repository.apply([transaction("a:1"), transaction("a:2")], refreshedAccountIDs: [], now: before)
        XCTAssertEqual(repository.cloudDirty().count, 2)

        // a:2 changes while the upload of the earlier version is in flight.
        try repository.apply([transaction("a:2")], refreshedAccountIDs: [], now: before.addingTimeInterval(5))
        repository.markCloudSynced(ids: ["a:1", "a:2"], at: before.addingTimeInterval(1))

        XCTAssertEqual(repository.cloudDirty().map(\.id), ["a:2"])
    }

    func testCalendarBookkeepingDoesNotMarkVisitsForUpload() throws {
        let repository = VisitRepository(container: PersistenceController.makeContainer(appGroupID: "", inMemory: true))
        let visit = try XCTUnwrap(repository.record(VisitEvent(arrival: Date(), departure: Date(), latitude: 51.5, longitude: -0.1,
                                                               horizontalAccuracy: 10)))
        repository.markCloudSynced(ids: [visit.id], at: Date().addingTimeInterval(1))
        XCTAssertTrue(repository.cloudDirty().isEmpty)

        repository.markSynced(visit, eventID: "dl1", hash: "h")
        repository.resetSyncState()

        XCTAssertTrue(repository.cloudDirty().isEmpty, "Calendar state is local to this device")
        try repository.applyPlace(nil, to: visit)
        XCTAssertEqual(repository.cloudDirty().count, 1, "A real change is")
    }

    func testPendingDeletionsAreKeptInTheStoreWithoutDuplicates() {
        let repository = TransactionRepository(container: PersistenceController.makeContainer(appGroupID: "", inMemory: true))
        repository.addPendingDeletions([transaction("a:1"), transaction("a:2")], at: Date(timeIntervalSince1970: 1))
        repository.addPendingDeletions([transaction("a:1")], at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(repository.pendingDeletions().map(\.transaction.id), ["a:2", "a:1"], "Oldest first, a:1 replaced")
        repository.removePendingDeletions(ids: ["a:2"])
        XCTAssertEqual(repository.pendingDeletions().map(\.transaction.id), ["a:1"])
    }
}
