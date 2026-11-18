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

        let fractional = #"{"active":true,"status":"grace_period","expiresAt":"2026-11-25T10:00:00.250Z","isTrial":false,"productId":"app.dayledger.pro.monthly"}"#
        let grace = try JSONDecoder().decode(Entitlement.self, from: Data(fractional.utf8))
        XCTAssertEqual(grace.status, .gracePeriod)
        XCTAssertEqual(grace.expiresAt?.timeIntervalSince1970 ?? 0, 1_795_600_800.25, accuracy: 0.001)

        let micro = #"{"active":true,"status":"active","expiresAt":"2026-11-25T10:00:00.123456+00:00"}"#
        let postgres = try JSONDecoder().decode(Entitlement.self, from: Data(micro.utf8))
        XCTAssertEqual(postgres.expiresAt?.timeIntervalSince1970 ?? 0, 1_795_600_800.123, accuracy: 0.001)
    }

    func testNoSubscriptionAndUnknownStatus() throws {
        let none = try JSONDecoder().decode(Entitlement.self, from: Data(#"{"active":false,"status":"none","expiresAt":null}"#.utf8))
        XCTAssertEqual(none.status, .none)
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

    func testTransactionRowUsesContractColumns() throws {
        let row = TransactionRow(userID: userID, id: "acc:tx1", accountID: "acc", merchant: "Costa", rawDescription: "COSTA",
                                 amountMinor: 340, currency: "GBP", direction: "debit", bankCategory: "PURCHASE", category: "coffee",
                                 occurredAt: Date(timeIntervalSince1970: 0), hasTime: true, isPending: false)
        let json = try keys(row)
        XCTAssertEqual(Set(json.keys), ["user_id", "id", "account_id", "merchant", "raw_description", "amount_minor", "currency",
                                        "direction", "bank_category", "category", "occurred_at", "has_time", "is_pending", "deleted_at"])
        XCTAssertNil(json["updated_at"], "updated_at belongs to the server trigger")
        XCTAssertTrue(json["deleted_at"] is NSNull, "Nulls are explicit so every object in a batch has the same keys")
        XCTAssertEqual(json["user_id"] as? String, userID.uuidString.lowercased())
        XCTAssertEqual(json["occurred_at"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(json["amount_minor"] as? Int, 340)
    }

    func testVisitRowUsesContractColumns() throws {
        let row = VisitRow(userID: userID, id: "v1", arrival: Date(timeIntervalSince1970: 0), departure: nil, latitude: 51.5, longitude: -0.1,
                           placeName: "Costa", placeCategory: nil, isNamedPlace: true, isResolved: true,
                           calendarEventID: nil, calendarContentHash: nil, calendarSyncedAt: nil)
        let json = try keys(row)
        XCTAssertEqual(Set(json.keys), ["user_id", "id", "arrival", "departure", "latitude", "longitude", "place_name", "place_category",
                                        "is_named_place", "is_resolved", "calendar_event_id", "calendar_content_hash",
                                        "calendar_synced_at", "deleted_at"])
    }

    func testSettingsRowAndDecodingServerRows() throws {
        let settings = SyncedSettings(locationLogging: true, calendarWriting: false, onlyNamedPlaces: true, minimumVisitMinutes: 10, aiAssistant: false)
        let json = try keys(UserSettingsRow(userID: userID, settings: settings))
        XCTAssertEqual(Set(json.keys), ["user_id", "settings"])
        let inner = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(Set(inner.keys), ["locationLogging", "calendarWriting", "onlyNamedPlaces", "minimumVisitMinutes", "aiAssistant"])

        let server = #"""
        {"user_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","id":"acc:tx1","account_id":"acc","merchant":"Costa","raw_description":"COSTA",
         "amount_minor":340,"currency":"GBP","direction":"debit","bank_category":"PURCHASE","category":"coffee",
         "occurred_at":"2026-11-18T08:30:00+00:00","has_time":true,"is_pending":false,
         "updated_at":"2026-11-18T09:00:00.123456+00:00","deleted_at":"2026-11-18T09:00:00.123456+00:00"}
        """#
        let row = try JSONDecoder().decode(TransactionRow.self, from: Data(server.utf8))
        XCTAssertEqual(row.userID, userID)
        XCTAssertEqual(row.updatedAt, "2026-11-18T09:00:00.123456+00:00", "Cursor text is kept exactly")
        XCTAssertNotNil(row.deletedAt)
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

        let result = try await client.fetchChanges(VisitRow.self, from: "visits", after: nil, pageSize: 2)

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

    func testUpsertBatchesWithMergeDuplicates() async throws {
        let http = StubHTTPClient()
        http.on("/rest/v1/transactions", status: 201, body: "")
        http.on("/rest/v1/transactions", status: 201, body: "")
        let rows = (0..<501).map { index in
            TransactionRow(userID: userID, id: "a:\(index)", accountID: "a", merchant: "M", rawDescription: "M", amountMinor: 100,
                           currency: "GBP", direction: "debit", bankCategory: "", category: "other", occurredAt: Date(), hasTime: false, isPending: false)
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
        XCTAssertEqual(none.status, .none)
        XCTAssertEqual(http.requests.last?.httpMethod, "GET")
        try await client.deleteAccount()
        XCTAssertEqual(http.requests.last?.httpMethod, "POST")
        XCTAssertNotNil(http.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }
}
