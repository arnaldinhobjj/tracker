import AccountKit
import LocationKit
import SecureStore
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
    /// The account's key, already on this device (as if from iCloud Keychain).
    let key = SyncKey(data: Data(repeating: 9, count: 32))!

    private struct Harness {
        let service: CloudSyncService
        let transactions: TransactionRepository
        let visits: VisitRepository
        let settings: AppSettings
        let defaults: UserDefaults
        let keyStore: InMemorySecureStore
        let http: StubHTTPClient
    }

    private func makeHarness(canWrite: Bool, keyOnDevice: Bool = true) -> Harness {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let transactions = TransactionRepository(container: container)
        let visits = VisitRepository(container: container)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let http = StubHTTPClient()
        let keyStore = InMemorySecureStore()
        if keyOnDevice {
            try? keyStore.set(key.data, for: SecureStoreKey.syncKey(userID: userID, keyID: key.id))
        }
        let auth = MockAuthService(session: MockAuthService.makeSession(userID: userID))
        let rest = SupabaseRESTClient(configuration: SupabaseConfiguration(urlString: "https://abc.supabase.co", anonKey: "anon"), tokens: auth, http: http)
        let service = CloudSyncService(rest: rest, keys: SyncKeyManager(store: keyStore), transactions: transactions, visits: visits,
                                       settings: settings, defaults: defaults)
        let userID = self.userID
        service.currentUserID = { userID }
        service.canWrite = { canWrite }
        return Harness(service: service, transactions: transactions, visits: visits, settings: settings, defaults: defaults,
                       keyStore: keyStore, http: http)
    }

    /// Replies for one sync run: the key registry, then the three tables.
    private func stubRun(_ h: Harness, transactions: String = "[]", visits: String = "[]", settings: String = "[]") {
        h.http.on("/rest/v1/sync_keys", body: #"[{"user_id":"\#(userID.uuidString.lowercased())","key_id":"\#(key.id)"}]"#)
        h.http.on("/rest/v1/transactions", body: transactions)
        h.http.on("/rest/v1/visits", body: visits)
        h.http.on("/rest/v1/user_settings", body: settings)
    }

    private func transaction(_ id: String, pending: Bool = false, at date: Date = Date()) -> BankTransaction {
        BankTransaction(id: id, accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA", amountMinor: 340, direction: .debit,
                        bankCategory: "PURCHASE", category: .coffee, timestamp: date, hasTime: true, isPending: pending)
    }

    /// A row as an older app version wrote it: plaintext columns, no payload.
    private func legacyRowJSON(_ id: String, merchant: String = "Pret", updatedAt: String, deletedAt: String? = nil) -> String {
        let deleted = deletedAt.map { "\"\($0)\"" } ?? "null"
        return #"{"user_id":"\#(userID.uuidString.lowercased())","id":"\#(id)","account_id":"a","merchant":"\#(merchant)","raw_description":"PRET","amount_minor":645,"currency":"GBP","direction":"debit","bank_category":"PURCHASE","category":"eatingOut","occurred_at":"\#(ISO8601.string(from: Date()))","has_time":true,"is_pending":false,"key_id":null,"payload":null,"updated_at":"\#(updatedAt)","deleted_at":\#(deleted)}"#
    }

    /// A row as the server returns it after another device uploaded it encrypted.
    private func encryptedRowJSON(_ transaction: BankTransaction, updatedAt: String, sealedWith sealKey: SyncKey? = nil) throws -> String {
        let row = try TransactionSyncRow(stored: transaction, userID: userID).sealing(with: sealKey ?? key)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json["updated_at"] = updatedAt
        return String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    }

    private func pushedRows(_ h: Harness, table: String) throws -> [[String: Any]] {
        try h.http.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/\(table)" }.flatMap { request in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [[String: Any]])
        }
    }

    private func decrypt(_ row: [String: Any]) throws -> TransactionSyncContent? {
        var json = row
        json["updated_at"] = "2026-01-01T00:00:00Z"
        let decoded = try JSONDecoder().decode(TransactionSyncRow.self, from: JSONSerialization.data(withJSONObject: json))
        return try decoded.opening(with: key).content
    }

    private func far(_ offset: TimeInterval) -> String {
        ISO8601.string(from: Date().addingTimeInterval(offset))
    }

    func testPullsAndDecryptsRemoteRowsThenPushesLocalChangesEncrypted() async throws {
        let h = makeHarness(canWrite: true)
        try h.transactions.apply([transaction("a:local")], refreshedAccountIDs: [])
        var remote = transaction("a:remote")
        remote.merchant = "Pret"

        let remoteJSON = try encryptedRowJSON(remote, updatedAt: far(-60))
        stubRun(h, transactions: "[\(remoteJSON)]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/transactions", status: 201, body: "")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        XCTAssertEqual(h.service.encryptionStatus, .ready)
        let today = h.transactions.transactions(on: Date())
        XCTAssertEqual(today.map(\.id).sorted(), ["a:local", "a:remote"])
        XCTAssertEqual(today.first { $0.id == "a:remote" }?.merchant, "Pret", "Decrypted")

        let rows = try pushedRows(h, table: "transactions")
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["a:local"], "Pulled rows aren't pushed back")
        XCTAssertEqual(rows.first?["user_id"] as? String, userID.uuidString.lowercased())
        XCTAssertEqual(rows.first?["key_id"] as? String, key.id)
        XCTAssertTrue(rows.first?["merchant"] is NSNull, "No plaintext is uploaded")
        XCTAssertEqual(try decrypt(XCTUnwrap(rows.first))?.merchant, "Costa Coffee")
        let body = String(data: try XCTUnwrap(h.http.requests.last { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/transactions" }?.httpBody), encoding: .utf8)
        XCTAssertFalse(body?.contains("Costa") ?? true)
        XCTAssertTrue(h.transactions.cloudDirty().isEmpty)

        // The cursor is kept: the next pull continues after the last row.
        stubRun(h, settings: #"[{"user_id":"\#(userID.uuidString.lowercased())","settings":{"locationLogging":false,"calendarWriting":false,"onlyNamedPlaces":true,"minimumVisitMinutes":5,"aiAssistant":false},"updated_at":"\#(far(0))"}]"#)
        await h.service.sync()
        let secondPull = try XCTUnwrap(h.http.requests.last(where: { $0.httpMethod == "GET" && $0.url?.path == "/rest/v1/transactions" }))
        let orFilter = URLComponents(url: secondPull.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "or" }?.value
        XCTAssertTrue(orFilter?.contains("id.gt.\"a:remote\"") == true, orFilter ?? "no cursor")
    }

    func testLegacyPlaintextRowsAreReuploadedEncrypted() async throws {
        let h = makeHarness(canWrite: true)
        stubRun(h, transactions: "[\(legacyRowJSON("a:old", updatedAt: far(-60)))]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/transactions", status: 201, body: "")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        XCTAssertEqual(h.transactions.transactions(on: Date()).first?.merchant, "Pret")
        let rows = try pushedRows(h, table: "transactions")
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["a:old"], "The plaintext copy is replaced by an encrypted one")
        XCTAssertTrue(rows.first?["merchant"] is NSNull)
        XCTAssertEqual(try decrypt(XCTUnwrap(rows.first))?.merchant, "Pret")
        XCTAssertTrue(h.transactions.cloudDirty().isEmpty)
    }

    func testFirstEncryptedSyncAfterUpgradeRereadsEverything() async throws {
        let h = makeHarness(canWrite: false)
        // An old cursor from a version without encryption.
        let cursor = try JSONEncoder().encode(SyncCursor(updatedAt: far(-600), id: "a:seen"))
        h.defaults.set(cursor, forKey: "cloud.cursor.\(userID.uuidString).transactions")
        h.defaults.set(cursor, forKey: "cloud.cursor.\(userID.uuidString).visits")
        stubRun(h)

        await h.service.sync()

        let pulls = h.http.requests.filter { $0.httpMethod == "GET" && ($0.url?.path == "/rest/v1/transactions" || $0.url?.path == "/rest/v1/visits") }
        XCTAssertEqual(pulls.count, 2)
        for pull in pulls {
            let items = URLComponents(url: pull.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertNil(items.first { $0.name == "or" }, "Pulled from the start, to find plaintext rows")
        }
        XCTAssertEqual(h.defaults.string(forKey: "cloud.keyID.\(userID.uuidString)"), key.id)
    }

    func testWithoutTheKeyNothingIsReadOrWritten() async throws {
        let h = makeHarness(canWrite: true, keyOnDevice: false)
        try h.transactions.apply([transaction("a:local")], refreshedAccountIDs: [])
        h.http.on("/rest/v1/user_settings", body: "[]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/sync_keys", body: #"[{"user_id":"\#(userID.uuidString.lowercased())","key_id":"\#(String(repeating: "c", count: 32))"}]"#)

        await h.service.sync()

        XCTAssertEqual(h.service.encryptionStatus, .waitingForKey)
        XCTAssertNil(h.service.error)
        XCTAssertFalse(h.http.requests.contains { $0.url?.path == "/rest/v1/transactions" }, "No data sync without the key")
        XCTAssertFalse(h.http.requests.contains { $0.url?.path == "/rest/v1/sync_keys" && $0.httpMethod == "POST" }, "Never a competing key")
        XCTAssertEqual(h.transactions.cloudDirty().count, 1, "Local changes wait for the key")
    }

    func testRowsSealedWithAnotherKeyAreSkippedButTheirDeletionsApply() async throws {
        let h = makeHarness(canWrite: false)
        try h.transactions.apply([transaction("a:gone")], refreshedAccountIDs: [])
        h.transactions.markCloudSynced(ids: ["a:gone"], at: Date().addingTimeInterval(1))
        let other = SyncKey.generate()
        var deleted = transaction("a:gone")
        deleted.merchant = "x"
        let tombstone = try TransactionSyncRow(stored: deleted, userID: userID, deletedAt: Date()).sealing(with: other)
        var tombstoneJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tombstone)) as? [String: Any])
        tombstoneJSON["updated_at"] = far(30)
        let unreadable = try encryptedRowJSON(transaction("a:foreign"), updatedAt: far(31), sealedWith: other)
        let tombstoneText = String(data: try JSONSerialization.data(withJSONObject: tombstoneJSON), encoding: .utf8)!
        stubRun(h, transactions: "[\(tombstoneText),\(unreadable)]")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        XCTAssertTrue(h.transactions.allStored().isEmpty, "Deletion applied, unreadable row skipped")
    }

    func testSoftDeletedRemoteRowsAreRemovedLocally() async throws {
        let h = makeHarness(canWrite: false)
        try h.transactions.apply([transaction("a:gone")], refreshedAccountIDs: [])
        h.transactions.markCloudSynced(ids: ["a:gone"], at: Date().addingTimeInterval(1))
        stubRun(h, transactions: "[\(legacyRowJSON("a:gone", updatedAt: far(30), deletedAt: far(30)))]")
        h.http.on("/rest/v1/transactions", status: 204, body: "")

        await h.service.sync()

        XCTAssertTrue(h.transactions.transactions(on: Date()).isEmpty)
        XCTAssertFalse(h.http.requests.contains { $0.httpMethod == "POST" }, "No writes without a subscription")
        // The plaintext tombstone left by an older version is hard-deleted (no subscription).
        let delete = try XCTUnwrap(h.http.requests.first { $0.httpMethod == "DELETE" })
        let items = URLComponents(url: delete.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "id" }?.value, #"in.("a:gone")"#)
    }

    func testNewerLocalEditSurvivesOlderRemoteVersion() async throws {
        let h = makeHarness(canWrite: false)
        try h.transactions.apply([transaction("a:1")], refreshedAccountIDs: [])
        // Unpushed local version (updated just now) vs a remote one written an hour ago.
        stubRun(h, transactions: "[\(legacyRowJSON("a:1", merchant: "Older", updatedAt: far(-3_600)))]")

        await h.service.sync()

        XCTAssertEqual(h.transactions.transactions(on: Date()).first?.merchant, "Costa Coffee")
    }

    func testLocalDeletionIsSoftWithSubscriptionAndHardWithout() async throws {
        for canWrite in [true, false] {
            let h = makeHarness(canWrite: canWrite)
            // A pending transaction settles under a new id: the pending one is deleted locally.
            try h.transactions.apply([transaction("a:pending:1", pending: true)], refreshedAccountIDs: ["a"])
            try h.transactions.apply([transaction("a:1")], refreshedAccountIDs: ["a"])

            stubRun(h)
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
                XCTAssertTrue(rows.first?["merchant"] is NSNull, "Tombstones are encrypted too")
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

    func testPendingDeletionsFromBeforeEncryptionAreKept() throws {
        let h = makeHarness(canWrite: true)
        // The format an older version stored: plaintext sync rows.
        let legacy = "[\(legacyRowJSON("a:pending:old", updatedAt: far(0), deletedAt: far(0)))]"
        h.defaults.set(Data(legacy.utf8), forKey: "cloud.pendingDeletes.transactions")

        let pending = h.service.pendingTombstones()

        XCTAssertEqual(pending.map(\.transaction.id), ["a:pending:old"])
        XCTAssertNil(h.defaults.data(forKey: "cloud.pendingDeletes.transactions"), "Converted once")
        XCTAssertEqual(h.service.pendingTombstones().map(\.transaction.id), ["a:pending:old"])
    }

    func testSignedOutDoesNothing() async {
        let h = makeHarness(canWrite: true)
        h.service.currentUserID = { nil }
        await h.service.sync()
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    // MARK: Visit sync (opt-in)

    private func recordVisit(_ h: Harness) throws {
        let arrival = Date().addingTimeInterval(-3_600)
        try h.visits.record(VisitEvent(arrival: arrival, departure: arrival.addingTimeInterval(1_800), latitude: 51.5, longitude: -0.12,
                                       horizontalAccuracy: 20))
    }

    func testVisitsAreNotUploadedUnlessVisitSyncIsOn() async throws {
        let h = makeHarness(canWrite: true)
        try recordVisit(h)
        stubRun(h)
        h.http.on("/rest/v1/user_settings", status: 201, body: "")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        XCTAssertFalse(h.http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/visits" })
    }

    func testVisitsAreUploadedEncryptedWhenVisitSyncIsOn() async throws {
        let h = makeHarness(canWrite: true)
        h.settings.visitSyncEnabled = true
        try recordVisit(h)
        stubRun(h)
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/visits", status: 201, body: "")

        await h.service.sync()

        XCTAssertNil(h.service.error, "\(String(describing: h.service.error))")
        let rows = try pushedRows(h, table: "visits")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.first?["latitude"] is NSNull, "No coordinates leave the device in plaintext")
        XCTAssertEqual(rows.first?["key_id"] as? String, key.id)
        XCTAssertTrue(h.visits.cloudDirty().isEmpty)
    }

    func testLegacyVisitsInTheAccountWaitForTheUsersDecision() async throws {
        let h = makeHarness(canWrite: true)
        let legacyVisit = #"{"user_id":"\#(userID.uuidString.lowercased())","id":"v-old","arrival":"2026-11-18T08:00:00Z","departure":null,"latitude":51.5,"longitude":-0.1,"place_name":"Costa","place_category":null,"is_named_place":true,"is_resolved":true,"calendar_event_id":null,"calendar_content_hash":null,"calendar_synced_at":null,"key_id":null,"payload":null,"updated_at":"\#(far(-60))","deleted_at":null}"#
        stubRun(h, visits: "[\(legacyVisit)]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")

        await h.service.sync()

        XCTAssertTrue(h.service.hasLegacyVisitsInCloud)
        XCTAssertEqual(h.visits.allVisits().first?.placeName, "Costa", "Kept locally")
        XCTAssertFalse(h.http.requests.contains { $0.url?.path == "/rest/v1/visits" && $0.httpMethod != "GET" },
                       "Neither re-uploaded nor deleted until the user chooses")

        // Choice 1: remove them from the account.
        h.http.on("/rest/v1/visits", status: 204, body: "")
        try await h.service.disableVisitSyncAndRemoveFromCloud()
        let delete = try XCTUnwrap(h.http.requests.last { $0.httpMethod == "DELETE" && $0.url?.path == "/rest/v1/visits" })
        let items = URLComponents(url: delete.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "user_id" }?.value, "eq.\(userID.uuidString.lowercased())")
        XCTAssertFalse(h.service.hasLegacyVisitsInCloud)
        XCTAssertFalse(h.settings.visitSyncEnabled)
        XCTAssertEqual(h.visits.allVisits().count, 1, "Visits on this iPhone stay")
    }

    func testKeepingLegacyVisitsReuploadsThemEncrypted() async throws {
        let h = makeHarness(canWrite: true)
        let legacyVisit = #"{"user_id":"\#(userID.uuidString.lowercased())","id":"v-old","arrival":"2026-11-18T08:00:00Z","departure":null,"latitude":51.5,"longitude":-0.1,"place_name":"Costa","place_category":null,"is_named_place":true,"is_resolved":true,"calendar_event_id":null,"calendar_content_hash":null,"calendar_synced_at":null,"key_id":null,"payload":null,"updated_at":"\#(far(-60))","deleted_at":null}"#
        stubRun(h, visits: "[\(legacyVisit)]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        await h.service.sync()
        XCTAssertTrue(h.service.hasLegacyVisitsInCloud)

        // Choice 2: keep them, with visit sync on.
        stubRun(h)
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/visits", status: 201, body: "")
        await h.service.enableVisitSync()

        let rows = try pushedRows(h, table: "visits")
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["v-old"])
        XCTAssertTrue(rows.first?["latitude"] is NSNull)
        XCTAssertFalse(h.service.hasLegacyVisitsInCloud)
    }

    func testStartingOverDeletesTheCloudCopyAndRegistersANewKey() async throws {
        let h = makeHarness(canWrite: true, keyOnDevice: false)
        try h.transactions.apply([transaction("a:1")], refreshedAccountIDs: [])
        h.transactions.markCloudSynced(ids: ["a:1"], at: Date().addingTimeInterval(1))
        h.http.on("/rest/v1/transactions", status: 204, body: "")
        h.http.on("/rest/v1/visits", status: 204, body: "")
        h.http.on("/rest/v1/sync_keys", status: 204, body: "")
        // The sync that follows: no key is registered any more, so this device creates and
        // registers one. (Its read-back isn't stubbed, so that run stops there, as if offline.)
        h.http.on("/rest/v1/user_settings", body: "[]")
        h.http.on("/rest/v1/user_settings", status: 201, body: "")
        h.http.on("/rest/v1/sync_keys", body: "[]")
        h.http.on("/rest/v1/sync_keys", status: 201, body: "")

        try await h.service.startEncryptionOver()

        let deletes = h.http.requests.filter { $0.httpMethod == "DELETE" }.compactMap(\.url?.path)
        XCTAssertEqual(deletes, ["/rest/v1/transactions", "/rest/v1/visits", "/rest/v1/sync_keys"])
        XCTAssertTrue(h.http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/sync_keys" }, "A new key is registered")
        XCTAssertEqual(h.transactions.cloudDirty().count, 1, "Everything here will be uploaded again with the new key")
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
        let key = SyncKey.generate()
        let oldCopy = try TransactionSyncRow(stored: deleted, userID: userID).sealing(with: key).opening(with: key)

        let changed = try repository.applyRemote([oldCopy], pendingDeletionIDs: ["a:pending"])

        XCTAssertFalse(changed)
        XCTAssertTrue(repository.allStored().isEmpty)
    }

    func testPulledVisitKeepsCalendarStateLocal() throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = VisitRepository(container: container)
        // A legacy row still carries another device's calendar columns; they must not be imported.
        let json = #"{"user_id":"\#(userID.uuidString.lowercased())","id":"v1","arrival":"2026-11-18T08:00:00Z","departure":null,"latitude":51.5,"longitude":-0.12,"place_name":"Costa Coffee","place_category":"cafe","is_named_place":true,"is_resolved":true,"calendar_event_id":"dlvother","calendar_content_hash":"hash-from-other-device","calendar_synced_at":"2026-11-18T09:00:00Z","updated_at":"2026-11-18T09:00:00Z","deleted_at":null}"#
        let row = try JSONDecoder().decode(VisitSyncRow.self, from: Data(json.utf8))

        try repository.applyRemote([row])

        let stored = try XCTUnwrap(repository.allVisits().first)
        XCTAssertEqual(stored.placeName, "Costa Coffee")
        XCTAssertNil(stored.calendarEventID)
        XCTAssertNil(stored.calendarContentHash)
        XCTAssertNil(stored.calendarSyncedAt)
        XCTAssertNil(stored.cloudSyncedAt, "A plaintext row stays dirty, to be re-uploaded encrypted")
    }

    func testDecryptedRowsAreMarkedSynced() throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = TransactionRepository(container: container)
        let key = SyncKey.generate()
        let transaction = BankTransaction(id: "a:1", accountID: "a", merchant: "Tesco", rawDescription: "TESCO", amountMinor: 1_287,
                                          direction: .debit, bankCategory: "PURCHASE", category: .groceries, timestamp: Date(),
                                          hasTime: true, isPending: false)
        let row = try TransactionSyncRow(stored: transaction, userID: userID).sealing(with: key).opening(with: key)

        XCTAssertTrue(try repository.applyRemote([row]))

        XCTAssertNotNil(repository.allStored().first?.cloudSyncedAt)
        XCTAssertTrue(repository.cloudDirty().isEmpty, "Already in the account, encrypted: nothing to push back")
    }
}
