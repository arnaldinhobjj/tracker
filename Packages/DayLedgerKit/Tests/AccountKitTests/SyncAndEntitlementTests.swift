import XCTest
@testable import AccountKit
import Networking
import SecureStore

final class EntitlementTests: XCTestCase {
    func testDecodesContractShapeWithAndWithoutFractionalSeconds() throws {
        let plain = #"{"active":true,"status":"trial","expiresAt":"2026-11-25T10:00:00Z","isTrial":true,"productId":"app.dayledger.pro.monthly"}"#
        let entitlement = try JSONDecoder().decode(Entitlement.self, from: Data(plain.utf8))
        XCTAssertTrue(entitlement.active)
        XCTAssertEqual(entitlement.status, .trial)
        XCTAssertTrue(entitlement.isTrial)
        XCTAssertEqual(entitlement.productId, "app.dayledger.pro.monthly")
        XCTAssertEqual(entitlement.expiresAt, Date(timeIntervalSince1970: 1_795_600_800))

        XCTAssertNil(entitlement.autoRenew)

        let fractional = #"{"active":true,"status":"grace_period","expiresAt":"2026-11-25T10:00:00.250Z","isTrial":false,"productId":"app.dayledger.pro.monthly","autoRenew":false}"#
        let grace = try JSONDecoder().decode(Entitlement.self, from: Data(fractional.utf8))
        XCTAssertEqual(grace.status, .gracePeriod)
        XCTAssertEqual(grace.autoRenew, false)
        XCTAssertEqual(grace.expiresAt?.timeIntervalSince1970 ?? 0, 1_795_600_800.25, accuracy: 0.001)

        let micro = #"{"active":true,"status":"active","expiresAt":"2026-11-25T10:00:00.123456+00:00"}"#
        let postgres = try JSONDecoder().decode(Entitlement.self, from: Data(micro.utf8))
        XCTAssertEqual(postgres.expiresAt?.timeIntervalSince1970 ?? 0, 1_795_600_800.123, accuracy: 0.001)
    }

    func testNoSubscriptionAndUnknownStatus() throws {
        let none = try JSONDecoder().decode(Entitlement.self, from: Data(#"{"active":false,"status":"none","expiresAt":null}"#.utf8))
        XCTAssertEqual(none.status, Entitlement.Status.none)
        XCTAssertFalse(none.isEntitled())

        let future = try JSONDecoder().decode(Entitlement.self, from: Data(#"{"active":false,"status":"paused_by_moon"}"#.utf8))
        XCTAssertEqual(future.status, .unknown)
        XCTAssertFalse(future.isEntitled())
    }

    func testExpiredEntitlementIsNotEntitledEvenIfFlaggedActive() {
        let now = Date()
        let stale = Entitlement(active: true, status: .active, expiresAt: now.addingTimeInterval(-60), isTrial: false, productId: nil)
        XCTAssertFalse(stale.isEntitled(now: now))
        let current = Entitlement(active: true, status: .billingRetry, expiresAt: now.addingTimeInterval(60), isTrial: false, productId: nil)
        XCTAssertFalse(current.isEntitled(now: now), "Billing retry doesn't unlock the app")
        XCTAssertTrue(Entitlement(active: true, status: .gracePeriod, expiresAt: now.addingTimeInterval(60), isTrial: false, productId: nil).isEntitled(now: now))
    }

    func testRoundTripsThroughCache() throws {
        let original = Entitlement(active: true, status: .trial, expiresAt: Date(timeIntervalSince1970: 1_795_600_800), isTrial: true, productId: "p")
        let decoded = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}

final class SyncRowTests: XCTestCase {
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func keys(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private let key = SyncKey(data: Data(repeating: 7, count: 32))!

    private func content() -> TransactionSyncContent {
        TransactionSyncContent(accountID: "acc", merchant: "Costa", rawDescription: "COSTA", amountMinor: 340, currency: "GBP",
                               direction: "debit", bankCategory: "PURCHASE", category: "coffee",
                               occurredAt: Date(timeIntervalSince1970: 0), hasTime: true, isPending: false)
    }

    func testTransactionRowUploadsOnlyCiphertextAndNullsEveryPlaintextColumn() throws {
        let row = try TransactionSyncRow(userID: userID, id: "acc:tx1", content: content()).sealing(with: key)
        let json = try keys(row)
        XCTAssertEqual(Set(json.keys), ["user_id", "id", "key_id", "payload", "deleted_at", "account_id", "merchant", "raw_description",
                                        "amount_minor", "currency", "direction", "bank_category", "category", "occurred_at",
                                        "has_time", "is_pending"])
        XCTAssertNil(json["updated_at"], "updated_at belongs to the server trigger")
        for column in ["account_id", "merchant", "raw_description", "amount_minor", "currency", "direction", "bank_category",
                       "category", "occurred_at", "has_time", "is_pending", "deleted_at"] {
            XCTAssertTrue(json[column] is NSNull, "\(column) must be an explicit null (erases legacy plaintext)")
        }
        XCTAssertEqual(json["user_id"] as? String, userID.uuidString.lowercased())
        XCTAssertEqual(json["key_id"] as? String, key.id)
        let payload = try XCTUnwrap(json["payload"] as? String)
        XCTAssertTrue(payload.hasPrefix("v1."))
        let text = String(data: try JSONEncoder().encode(row), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("Costa") || text.contains("COSTA") || text.contains("340"), "No plaintext leaves the device")
    }

    func testUnsealedRowsCannotBeEncoded() {
        XCTAssertThrowsError(try JSONEncoder().encode(TransactionSyncRow(userID: userID, id: "t", content: content())))
        let visit = VisitSyncRow(userID: userID, id: "v1", content: VisitSyncContent(
            arrival: Date(), departure: nil, latitude: 51.5, longitude: -0.1, placeName: "Costa", placeCategory: nil,
            isNamedPlace: true, isResolved: true))
        XCTAssertThrowsError(try JSONEncoder().encode(visit))
    }

    func testVisitRowRoundTripsThroughTheServerEncrypted() throws {
        let original = VisitSyncContent(arrival: Date(timeIntervalSince1970: 1_000), departure: Date(timeIntervalSince1970: 2_000),
                                        latitude: 51.5, longitude: -0.1, placeName: "Costa", placeCategory: "cafe",
                                        isNamedPlace: true, isResolved: true)
        let sealed = try VisitSyncRow(userID: userID, id: "v1", content: original).sealing(with: key)
        var json = try keys(sealed)
        XCTAssertEqual(Set(json.keys), ["user_id", "id", "key_id", "payload", "deleted_at", "arrival", "departure", "latitude",
                                        "longitude", "place_name", "place_category", "is_named_place", "is_resolved",
                                        "calendar_event_id", "calendar_content_hash", "calendar_synced_at"])
        XCTAssertTrue(json["latitude"] is NSNull)
        // What the server sends back.
        json["updated_at"] = "2026-11-18T09:00:00.123456+00:00"
        let pulled = try JSONDecoder().decode(VisitSyncRow.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(pulled.content, "Encrypted until opened")
        XCTAssertFalse(pulled.isLegacyPlaintext)
        XCTAssertEqual(try pulled.opening(with: key).content, original)
    }

    func testLegacyPlaintextRowsAreStillReadAndFlagged() throws {
        let server = #"""
        {"user_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","id":"acc:tx1","account_id":"acc","merchant":"Costa","raw_description":"COSTA",
         "amount_minor":340,"currency":"GBP","direction":"debit","bank_category":"PURCHASE","category":"coffee",
         "occurred_at":"2026-11-18T08:30:00+00:00","has_time":true,"is_pending":false,"key_id":null,"payload":null,
         "updated_at":"2026-11-18T09:00:00.123456+00:00","deleted_at":"2026-11-18T09:00:00.123456+00:00"}
        """#
        let row = try JSONDecoder().decode(TransactionSyncRow.self, from: Data(server.utf8))
        XCTAssertEqual(row.userID, userID)
        XCTAssertEqual(row.updatedAt, "2026-11-18T09:00:00.123456+00:00", "Cursor text is kept exactly")
        XCTAssertNotNil(row.deletedAt)
        XCTAssertTrue(row.isLegacyPlaintext)
        XCTAssertEqual(row.content?.merchant, "Costa")
        XCTAssertEqual(row.content?.amountMinor, 340)
        XCTAssertEqual(try row.opening(with: key), row, "Nothing to decrypt")

        let legacyVisit = #"{"user_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","id":"v1","arrival":"2026-11-18T08:00:00Z","departure":null,"latitude":51.5,"longitude":-0.1,"place_name":"Costa","place_category":null,"is_named_place":true,"is_resolved":true,"calendar_event_id":"x","calendar_content_hash":null,"calendar_synced_at":null,"updated_at":"2026-11-18T09:00:00+00:00","deleted_at":null}"#
        let visit = try JSONDecoder().decode(VisitSyncRow.self, from: Data(legacyVisit.utf8))
        XCTAssertTrue(visit.isLegacyPlaintext)
        XCTAssertEqual(visit.content?.placeName, "Costa")
    }

    func testSettingsRowIncludesVisitSyncAndOlderRowsReadAsOff() throws {
        let settings = SyncedSettings(locationLogging: true, calendarWriting: false, onlyNamedPlaces: true, minimumVisitMinutes: 10,
                                      aiAssistant: false, visitSync: true)
        let json = try keys(UserSettingsSyncRow(userID: userID, settings: settings))
        XCTAssertEqual(Set(json.keys), ["user_id", "settings"])
        let inner = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(Set(inner.keys), ["locationLogging", "calendarWriting", "onlyNamedPlaces", "minimumVisitMinutes", "aiAssistant", "visitSync"])

        let old = try JSONDecoder().decode(SyncedSettings.self, from: Data(#"{"locationLogging":true,"aiAssistant":true}"#.utf8))
        XCTAssertFalse(old.visitSync, "Settings from older versions never turn visit sync on")
    }
}

final class SyncCipherTests: XCTestCase {
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    func testKeyIDIsAStableFingerprint() throws {
        let key = try XCTUnwrap(SyncKey(data: Data(repeating: 1, count: 32)))
        XCTAssertEqual(key.id.count, 32)
        XCTAssertTrue(key.id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(SyncKey(data: Data(repeating: 1, count: 32))?.id, key.id)
        XCTAssertNotEqual(SyncKey(data: Data(repeating: 2, count: 32))?.id, key.id)
        XCTAssertNil(SyncKey(data: Data(repeating: 1, count: 16)), "Only 256-bit keys")
        XCTAssertNotEqual(SyncKey.generate(), SyncKey.generate())
    }

    func testRoundTripAndFreshNonces() throws {
        let key = SyncKey.generate()
        let first = try SyncCipher.seal(["merchant": "Costa"], table: "transactions", userID: userID, rowID: "t1", key: key)
        let second = try SyncCipher.seal(["merchant": "Costa"], table: "transactions", userID: userID, rowID: "t1", key: key)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext, "Random nonce per seal")
        XCTAssertEqual(first.keyID, key.id)
        let opened = try SyncCipher.open([String: String].self, from: first, table: "transactions", userID: userID, rowID: "t1", key: key)
        XCTAssertEqual(opened, ["merchant": "Costa"])
    }

    func testPayloadsAreBoundToTheirRowUserAndTable() throws {
        let key = SyncKey.generate()
        let sealed = try SyncCipher.seal(["a": 1], table: "transactions", userID: userID, rowID: "t1", key: key)
        let attempts: [(String, UUID, String)] = [("transactions", userID, "t2"), ("visits", userID, "t1"), ("transactions", UUID(), "t1")]
        for (table, user, row) in attempts {
            XCTAssertThrowsError(try SyncCipher.open([String: Int].self, from: sealed, table: table, userID: user, rowID: row, key: key)) {
                XCTAssertEqual($0 as? SyncCryptoError, .authenticationFailed)
            }
        }
    }

    func testTamperingWrongKeyAndGarbageAreRejected() throws {
        let key = SyncKey.generate()
        var sealed = try SyncCipher.seal(["a": 1], table: "t", userID: userID, rowID: "r", key: key)

        let other = SyncKey.generate()
        XCTAssertThrowsError(try SyncCipher.open([String: Int].self, from: sealed, table: "t", userID: userID, rowID: "r", key: other)) {
            XCTAssertEqual($0 as? SyncCryptoError, .wrongKey(expected: other.id, found: key.id))
        }

        var bytes = try XCTUnwrap(Data(base64Encoded: String(sealed.ciphertext.dropFirst(3))))
        bytes[bytes.count - 1] ^= 0x01
        sealed.ciphertext = "v1." + bytes.base64EncodedString()
        XCTAssertThrowsError(try SyncCipher.open([String: Int].self, from: sealed, table: "t", userID: userID, rowID: "r", key: key)) {
            XCTAssertEqual($0 as? SyncCryptoError, .authenticationFailed)
        }

        for garbage in ["", "v1.", "v1.not-base64!", "v2.AAAA"] {
            let payload = SealedPayload(keyID: key.id, ciphertext: garbage)
            XCTAssertThrowsError(try SyncCipher.open([String: Int].self, from: payload, table: "t", userID: userID, rowID: "r", key: key)) {
                XCTAssertEqual($0 as? SyncCryptoError, .malformed, garbage)
            }
        }
    }
}

final class SyncKeyManagerTests: XCTestCase {
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func makeClient(_ http: StubHTTPClient) -> SupabaseRESTClient {
        SupabaseRESTClient(configuration: SupabaseConfiguration(urlString: "https://abc.supabase.co", anonKey: "anon"),
                           tokens: MockAuthService(session: MockAuthService.makeSession(userID: userID)), http: http)
    }

    private func record(_ keyID: String) -> String {
        #"[{"user_id":"\#(userID.uuidString.lowercased())","key_id":"\#(keyID)"}]"#
    }

    func testFirstDeviceCreatesSavesAndRegistersAKey() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecureStore()
        let fresh = SyncKey.generate()
        http.on("/rest/v1/sync_keys", body: "[]")
        http.on("/rest/v1/sync_keys", status: 201, body: "")
        http.on("/rest/v1/sync_keys", body: record(fresh.id))
        let manager = SyncKeyManager(store: store, generate: { fresh })

        let result = try await manager.resolve(userID: userID, rest: makeClient(http))

        XCTAssertEqual(result, .ready(fresh))
        XCTAssertEqual(manager.localKey(userID: userID, keyID: fresh.id), fresh, "Saved before registering")
        let post = try XCTUnwrap(http.requests(to: "/rest/v1/sync_keys").first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.value(forHTTPHeaderField: "Prefer"), "resolution=ignore-duplicates,return=minimal")
        XCTAssertEqual(post.queryValue("on_conflict"), "user_id")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [[String: String]])
        XCTAssertEqual(sent, [["user_id": userID.uuidString.lowercased(), "key_id": fresh.id]], "Only the id is sent, never the key")
    }

    func testExistingKeyIsUsedWhenThisDeviceHasIt() async throws {
        let store = InMemorySecureStore()
        let key = SyncKey.generate()
        try store.set(key.data, for: SecureStoreKey.syncKey(userID: userID, keyID: key.id))
        let http = StubHTTPClient()
        http.on("/rest/v1/sync_keys", body: record(key.id))

        let result = try await SyncKeyManager(store: store).resolve(userID: userID, rest: makeClient(http))

        XCTAssertEqual(result, .ready(key))
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" }, "Never registers a second key")
    }

    func testAnotherDevicesKeyThatHasntArrivedIsMissing() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/sync_keys", body: record(String(repeating: "a", count: 32)))
        let result = try await SyncKeyManager(store: InMemorySecureStore()).resolve(userID: userID, rest: makeClient(http))
        XCTAssertEqual(result, .missing(keyID: String(repeating: "a", count: 32)))
    }

    func testLosingTheRaceDiscardsOurKey() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecureStore()
        let winner = String(repeating: "b", count: 32)
        http.on("/rest/v1/sync_keys", body: "[]")
        http.on("/rest/v1/sync_keys", status: 201, body: "")
        http.on("/rest/v1/sync_keys", body: record(winner))

        let ours = SyncKey.generate()
        let result = try await SyncKeyManager(store: store, generate: { ours }).resolve(userID: userID, rest: makeClient(http))

        XCTAssertEqual(result, .missing(keyID: winner))
        XCTAssertNil(try store.data(for: SecureStoreKey.syncKey(userID: userID, keyID: ours.id)), "The losing key is removed")
    }
}

final class SupabaseRESTClientTests: XCTestCase {
    let configuration = SupabaseConfiguration(urlString: "https://abc.supabase.co", anonKey: "anon-key")
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func visitJSON(_ id: String, updatedAt: String) -> String {
        #"{"user_id":"\#(userID.uuidString.lowercased())","id":"\#(id)","arrival":"2026-11-18T08:00:00Z","departure":null,"latitude":51.5,"longitude":-0.1,"place_name":null,"place_category":null,"is_named_place":false,"is_resolved":false,"calendar_event_id":null,"calendar_content_hash":null,"calendar_synced_at":null,"updated_at":"\#(updatedAt)","deleted_at":null}"#
    }

    private func makeClient(http: StubHTTPClient) -> SupabaseRESTClient {
        SupabaseRESTClient(configuration: configuration, tokens: MockAuthService(session: MockAuthService.makeSession()), http: http)
    }

    func testPagingStopsOnShortPage() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/visits", body: "[\(visitJSON("a", updatedAt: "2026-11-18T09:00:00+00:00")),\(visitJSON("b", updatedAt: "2026-11-18T09:00:00+00:00"))]")
        http.on("/rest/v1/visits", body: "[\(visitJSON("c", updatedAt: "2026-11-18T09:05:00+00:00"))]")
        http.on("/rest/v1/visits", body: "[]") // Must never be requested.
        let client = makeClient(http: http)

        let result = try await client.fetchChanges(VisitSyncRow.self, from: "visits", after: nil, pageSize: 2)

        XCTAssertEqual(result.rows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(result.cursor, SyncCursor(updatedAt: "2026-11-18T09:05:00+00:00", id: "c"))
        let requests = http.requests(to: "/rest/v1/visits")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].queryValue("order"), "updated_at.asc,id.asc")
        XCTAssertEqual(requests[0].queryValue("limit"), "2")
        XCTAssertNil(requests[0].queryValue("or"), "First pull has no cursor")
        // The second page continues after the last row, breaking the updated_at tie by id.
        XCTAssertEqual(requests[1].queryValue("or"),
                       #"(updated_at.gt."2026-11-18T09:00:00+00:00",and(updated_at.eq."2026-11-18T09:00:00+00:00",id.gt."b"))"#)
        XCTAssertTrue(requests[1].url?.absoluteString.contains("%2B00%3A00") == true, "+ is percent-encoded")
    }

    func testEachPageIsHandedOverBeforeTheNextIsFetched() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/visits", body: "[\(visitJSON("a", updatedAt: "2026-11-18T09:00:00+00:00")),\(visitJSON("b", updatedAt: "2026-11-18T09:01:00+00:00"))]")
        http.on("/rest/v1/visits", body: "[\(visitJSON("c", updatedAt: "2026-11-18T09:05:00+00:00"))]")
        var seen: [(ids: [String], cursor: SyncCursor?, requestsSoFar: Int)] = []

        try await makeClient(http: http).forEachChangePage(VisitSyncRow.self, from: "visits", after: nil, pageSize: 2) { rows, cursor in
            seen.append((rows.map(\.id), cursor, http.requests(to: "/rest/v1/visits").count))
        }

        XCTAssertEqual(seen.map { $0.ids }, [["a", "b"], ["c"]])
        XCTAssertEqual(seen.map { $0.requestsSoFar }, [1, 2], "Page 2 is fetched only after page 1 was handled")
        XCTAssertEqual(seen.first?.cursor, SyncCursor(updatedAt: "2026-11-18T09:01:00+00:00", id: "b"))
        XCTAssertEqual(seen.last?.cursor, SyncCursor(updatedAt: "2026-11-18T09:05:00+00:00", id: "c"))
    }

    func testUpsertBatchesWithMergeDuplicates() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/transactions", status: 201, body: "")
        http.on("/rest/v1/transactions", status: 201, body: "")
        let key = SyncKey.generate()
        let rows = try (0..<501).map { index in
            try TransactionSyncRow(userID: userID, id: "a:\(index)", content: TransactionSyncContent(
                accountID: "a", merchant: "M", rawDescription: "M", amountMinor: 100, currency: "GBP", direction: "debit",
                bankCategory: "", category: "other", occurredAt: Date(), hasTime: false, isPending: false)).sealing(with: key)
        }

        try await makeClient(http: http).upsert(rows, into: "transactions", onConflict: "user_id,id")

        let requests = http.requests(to: "/rest/v1/transactions")
        XCTAssertEqual(requests.count, 2, "500 + 1")
        XCTAssertEqual(requests[0].queryValue("on_conflict"), "user_id,id")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [[String: Any]])
        XCTAssertEqual(first.count, 500)
    }

    func testEdgeFunctions() async throws {
        let http = StubHTTPClient()
        http.on("/functions/v1/verify-subscription", body: #"{"active":true,"status":"trial","expiresAt":"2026-11-25T10:00:00Z","isTrial":true,"productId":"app.dayledger.pro.monthly"}"#)
        http.on("/functions/v1/entitlement", body: #"{"active":false,"status":"none"}"#)
        http.on("/functions/v1/delete-account", body: #"{"deleted":true}"#)
        let client = makeClient(http: http)

        let verified = try await client.verifySubscription(signedTransaction: "jws")
        XCTAssertEqual(verified.status, .trial)
        XCTAssertEqual(http.requests.last?.jsonBody()?["signedTransaction"] as? String, "jws")
        let none = try await client.fetchEntitlement()
        XCTAssertEqual(none.status, Entitlement.Status.none)
        XCTAssertEqual(http.requests.last?.httpMethod, "GET")
        try await client.deleteAccount()
        XCTAssertEqual(http.requests.last?.httpMethod, "POST")
        XCTAssertNotNil(http.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testDeleteAllRemovesEveryRowOfTheUserInATable() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/visits", status: 204, body: "")
        try await makeClient(http: http).deleteAll(from: "visits", userID: userID)
        let request = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.queryValue("user_id"), "eq.\(userID.uuidString.lowercased())")
        XCTAssertNil(request.queryValue("id"), "Every row, not a list of ids")
    }
}
