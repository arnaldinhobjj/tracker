import AccountKit
import SharedModels
import XCTest
@testable import DayLedger

final class CloudMergeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    let t2 = Date(timeIntervalSince1970: 3_000)

    func testDirtiness() {
        XCTAssertTrue(CloudMerge.isDirty(updatedAt: t0, syncedAt: nil), "Never synced")
        XCTAssertTrue(CloudMerge.isDirty(updatedAt: t1, syncedAt: t0), "Changed since")
        XCTAssertFalse(CloudMerge.isDirty(updatedAt: t0, syncedAt: t1))
        XCTAssertFalse(CloudMerge.isDirty(updatedAt: t1, syncedAt: t1))
    }

    func testRemoteWinsOverUntouchedOrMissingLocalRows() {
        XCTAssertTrue(CloudMerge.shouldApplyRemote(remoteUpdatedAt: t0, localUpdatedAt: nil, localSyncedAt: nil, localExists: false))
        XCTAssertTrue(CloudMerge.shouldApplyRemote(remoteUpdatedAt: t0, localUpdatedAt: t1, localSyncedAt: t2, localExists: true))
    }

    func testLastWriteWinsWhenBothChanged() {
        // Local edit at t1 not yet pushed (synced at t0).
        XCTAssertTrue(CloudMerge.shouldApplyRemote(remoteUpdatedAt: t2, localUpdatedAt: t1, localSyncedAt: t0, localExists: true))
        XCTAssertFalse(CloudMerge.shouldApplyRemote(remoteUpdatedAt: t0, localUpdatedAt: t1, localSyncedAt: t0, localExists: true))
        XCTAssertTrue(CloudMerge.shouldApplyRemote(remoteUpdatedAt: t1, localUpdatedAt: t1, localSyncedAt: t0, localExists: true), "Ties go to the server")
        XCTAssertFalse(CloudMerge.shouldApplyRemote(remoteUpdatedAt: nil, localUpdatedAt: t1, localSyncedAt: t0, localExists: true))
    }

    func testSettingsActions() {
        // Nothing on the server yet: push.
        XCTAssertEqual(CloudMerge.settingsAction(localChangedAt: nil, lastPushedAt: nil, remoteUpdatedAt: nil, remoteExists: false, remoteDiffers: true), .push)
        // New device, untouched settings: take the account's.
        XCTAssertEqual(CloudMerge.settingsAction(localChangedAt: nil, lastPushedAt: nil, remoteUpdatedAt: t1, remoteExists: true, remoteDiffers: true), .applyRemote)
        // Local edit newer than the server's: push.
        XCTAssertEqual(CloudMerge.settingsAction(localChangedAt: t2, lastPushedAt: t0, remoteUpdatedAt: t1, remoteExists: true, remoteDiffers: true), .push)
        // Server newer than the local edit: take it.
        XCTAssertEqual(CloudMerge.settingsAction(localChangedAt: t1, lastPushedAt: t0, remoteUpdatedAt: t2, remoteExists: true, remoteDiffers: true), .applyRemote)
        // In step.
        XCTAssertEqual(CloudMerge.settingsAction(localChangedAt: t0, lastPushedAt: t1, remoteUpdatedAt: t1, remoteExists: true, remoteDiffers: false), .none)
    }
}

@MainActor
final class CloudSyncServiceTests: XCTestCase {
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private struct Harness {
        let service: CloudSyncService
        let transactions: TransactionRepository
        let visits: VisitRepository
        let settings: AppSettings
        let http: StubHTTPClient
    }

    private func makeHarness(canWrite: Bool) -> Harness {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let transactions = TransactionRepository(container: container)
        let visits = VisitRepository(container: container)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let http = StubHTTPClient()
        let auth = MockAuthService(session: MockAuthService.makeSession(userID: userID))
        let rest = SupabaseRESTClient(configuration: SupabaseConfiguration(urlString: "https://abc.supabase.co", anonKey: "anon"), tokens: auth, http: http)
        let service = CloudSyncService(rest: rest, transactions: transactions, visits: visits, settings: settings, defaults: defaults)
        let userID = self.userID
        service.currentUserID = { userID }
        service.canWrite = { canWrite }
        return Harness(service: service, transactions: transactions, visits: visits, settings: settings, http: http)
    }

    private func transaction(_ id: String, pending: Bool = false, at date: Date = Date()) -> BankTransaction {
        BankTransaction(id: id, accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA", amountMinor: 340, direction: .debit,
                        bankCategory: "PURCHASE", category: .coffee, timestamp: date, hasTime: true, isPending: pending)
    }

    private func rowJSON(_ id: String, merchant: String = "Pret", updatedAt: String, deletedAt: String? = nil) -> String {
        let deleted = deletedAt.map { "\"\($0)\"" } ?? "null"
        return #"{"user_id":"\#(userID.uuidString.lowercased())","id":"\#(id)","account_id":"a","merchant":"\#(merchant)","raw_description":"PRET","amount_minor":645,"currency":"GBP","direction":"debit","bank_category":"PURCHASE","category":"eatingOut","occurred_at":"\#(ISO8601.string(from: Date()))","has_time":true,"is_pending":false,"updated_at":"\#(updatedAt)","deleted_at":\#(deleted)}"#
    }

    private func far(_ offset: TimeInterval) -> String {
        ISO8601.string(from: Date().addingTimeInterval(offset))
    }

    func testPullsRemoteRowsThenPushesLocalChanges() async throws {
        let h = makeHarness(canWrite: true)
        try h.transactions.apply([transaction("a:local")], refreshedAccountIDs: [])

        h.http.on("/rest/v1/transactions", body: "[\(rowJSON("a:remote", updatedAt: far(-60)))]")
        h.http.on("/rest/v1/visits", body: "[]")
        h.http.on("/rest/v1/user_settings", body: "[]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/transactions", status: 201, body: "")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        let today = h.transactions.transactions(on: Date()).map(\.id).sorted()
        XCTAssertEqual(today, ["a:local", "a:remote"])

        let push = try XCTUnwrap(h.http.requests.last(where: { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/transactions" }))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(push.httpBody)) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["a:local"], "Pulled rows aren't pushed back")
        XCTAssertEqual(rows.first?["user_id"] as? String, userID.uuidString.lowercased())
        XCTAssertTrue(h.transactions.cloudDirty().isEmpty)

        // The cursor is kept: the next pull continues after the last row.
        h.http.on("/rest/v1/transactions", body: "[]")
        h.http.on("/rest/v1/visits", body: "[]")
        h.http.on("/rest/v1/user_settings", body: #"[{"user_id":"\#(userID.uuidString.lowercased())","settings":{"locationLogging":false,"calendarWriting":false,"onlyNamedPlaces":true,"minimumVisitMinutes":5,"aiAssistant":false},"updated_at":"\#(far(0))"}]"#)
        await h.service.sync()
        let secondPull = try XCTUnwrap(h.http.requests.last(where: { $0.httpMethod == "GET" && $0.url?.path == "/rest/v1/transactions" }))
        let orFilter = URLComponents(url: secondPull.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "or" }?.value
        XCTAssertTrue(orFilter?.contains("id.gt.\"a:remote\"") == true, orFilter ?? "no cursor")
    }

    func testSoftDeletedRemoteRowsAreRemovedLocally() async throws {
        let h = makeHarness(canWrite: false)
        try h.transactions.apply([transaction("a:gone")], refreshedAccountIDs: [])
        h.transactions.markCloudSynced(ids: ["a:gone"], at: Date().addingTimeInterval(1))

        h.http.on("/rest/v1/transactions", body: "[\(rowJSON("a:gone", updatedAt: far(30), deletedAt: far(30)))]")
        h.http.on("/rest/v1/visits", body: "[]")
        h.http.on("/rest/v1/user_settings", body: "[]")

        await h.service.sync()

        XCTAssertTrue(h.transactions.transactions(on: Date()).isEmpty)
        XCTAssertFalse(h.http.requests.contains { $0.httpMethod == "POST" }, "No writes without a subscription")
    }

    func testNewerLocalEditSurvivesOlderRemoteVersion() async throws {
        let h = makeHarness(canWrite: false)
        try h.transactions.apply([transaction("a:1")], refreshedAccountIDs: [])
        // Unpushed local version (updated just now) vs a remote one written an hour ago.
        h.http.on("/rest/v1/transactions", body: "[\(rowJSON("a:1", merchant: "Older", updatedAt: far(-3_600)))]")
        h.http.on("/rest/v1/visits", body: "[]")
        h.http.on("/rest/v1/user_settings", body: "[]")

        await h.service.sync()

        XCTAssertEqual(h.transactions.transactions(on: Date()).first?.merchant, "Costa Coffee")
    }

    func testLocalDeletionIsSoftWithSubscriptionAndHardWithout() async throws {
        for canWrite in [true, false] {
            let h = makeHarness(canWrite: canWrite)
            // A pending transaction settles under a new id: the pending one is deleted locally.
            try h.transactions.apply([transaction("a:pending:1", pending: true)], refreshedAccountIDs: ["a"])
            try h.transactions.apply([transaction("a:1")], refreshedAccountIDs: ["a"])

            h.http.on("/rest/v1/transactions", body: "[]")
            h.http.on("/rest/v1/visits", body: "[]")
            h.http.on("/rest/v1/user_settings", body: "[]")
            h.http.on("/rest/v1/user_settings", status: 201, body: "")
            h.http.on("/rest/v1/transactions", status: canWrite ? 201 : 204, body: "")
            h.http.on("/rest/v1/transactions", status: 201, body: "")

            await h.service.sync()
            XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")

            if canWrite {
                let firstPost = try XCTUnwrap(h.http.requests.first { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/transactions" })
                let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(firstPost.httpBody)) as? [[String: Any]])
                XCTAssertEqual(rows.first?["id"] as? String, "a:pending:1")
                XCTAssertNotNil(rows.first?["deleted_at"] as? String, "Soft delete")
                XCTAssertEqual(rows.first?["user_id"] as? String, userID.uuidString.lowercased())
            } else {
                let delete = try XCTUnwrap(h.http.requests.first { $0.httpMethod == "DELETE" })
                let items = URLComponents(url: delete.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(items.first { $0.name == "user_id" }?.value, "eq.\(userID.uuidString.lowercased())")
                XCTAssertEqual(items.first { $0.name == "id" }?.value, #"in.("a:pending:1")"#)
                XCTAssertFalse(h.http.requests.contains { $0.httpMethod == "POST" }, "Lapsed users can't upsert")
            }
        }
    }

    func testSignedOutDoesNothing() async {
        let h = makeHarness(canWrite: true)
        h.service.currentUserID = { nil }
        await h.service.sync()
        XCTAssertTrue(h.http.requests.isEmpty)
    }
}

/// Review fixes: pulled rows must not undo local deletions or import another device's calendar state.
@MainActor
final class CloudApplyRemoteTests: XCTestCase {
    private let userID = UUID()

    func testPulledRowDoesNotResurrectAPendingLocalDeletion() throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = TransactionRepository(container: container)
        let deleted = BankTransaction(id: "a:pending", accountID: "a", merchant: "Tesco", rawDescription: "TESCO", amountMinor: 1_287,
                                      direction: .debit, bankCategory: "PURCHASE", category: .groceries, timestamp: Date(),
                                      hasTime: true, isPending: true)
        let oldCopy = TransactionSyncRow(stored: deleted, userID: userID)

        let changed = try repository.applyRemote([oldCopy], pendingDeletionIDs: ["a:pending"])

        XCTAssertFalse(changed)
        XCTAssertTrue(repository.allStored().isEmpty)
    }

    func testPulledVisitKeepsCalendarStateLocal() throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = VisitRepository(container: container)
        let row = VisitSyncRow(userID: userID, id: UUID().uuidString, arrival: Date(), departure: nil, latitude: 51.5, longitude: -0.12,
                               placeName: "Costa Coffee", placeCategory: "cafe", isNamedPlace: true, isResolved: true,
                               calendarEventID: "dlvother", calendarContentHash: "hash-from-other-device", calendarSyncedAt: Date())

        try repository.applyRemote([row])

        let stored = try XCTUnwrap(repository.allVisits().first)
        XCTAssertEqual(stored.placeName, "Costa Coffee")
        XCTAssertNil(stored.calendarEventID)
        XCTAssertNil(stored.calendarContentHash)
        XCTAssertNil(stored.calendarSyncedAt)
    }
}
