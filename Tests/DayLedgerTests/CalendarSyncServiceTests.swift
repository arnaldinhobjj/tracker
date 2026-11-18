import CalendarKit
import LocationKit
import Networking
import SecureStore
import SharedModels
import XCTest
@testable import DayLedger

/// End-to-end: visit + matching transaction -> one Google event, and re-syncing never duplicates.
@MainActor
final class CalendarSyncServiceTests: XCTestCase {
    func testSyncWritesOnceAndUpdatesInsteadOfDuplicating() async throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let visits = VisitRepository(container: container)
        let transactions = TransactionRepository(container: container)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.calendarWritingEnabled = true

        let store = InMemorySecureStore()
        try store.setValue(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture), for: SecureStoreKey.googleTokens)
        let http = StubHTTPClient()
        let auth = GoogleAuthService(configuration: GoogleOAuthConfiguration(clientID: "1-x.apps.googleusercontent.com"), store: store, http: http)
        let sync = CalendarSyncService(auth: auth, client: GoogleCalendarClient(tokens: auth, http: http), visits: visits,
                                       transactions: transactions, settings: settings, defaults: defaults)

        let now = Date()
        let arrival = now.addingTimeInterval(-3_600)
        let departure = now.addingTimeInterval(-1_800)
        let visit = try XCTUnwrap(visits.record(VisitEvent(arrival: arrival, departure: departure, latitude: 51.5, longitude: -0.12, horizontalAccuracy: 20)))
        try visits.applyPlace(ResolvedPlace(name: "Costa Coffee", category: "MKPOICategoryCafe", isPointOfInterest: true), to: visit)

        func coffee(_ id: String, _ pence: Int) -> BankTransaction {
            BankTransaction(id: id, accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA", amountMinor: pence, direction: .debit,
                            bankCategory: "PURCHASE", category: .coffee, timestamp: arrival.addingTimeInterval(300), hasTime: true, isPending: false)
        }
        try transactions.apply([coffee("t1", 340)], refreshedAccountIDs: [])

        // First sync: finds no DayLedger calendar, creates one, inserts one event.
        http.on("/users/me/calendarList", body: #"{"items":[]}"#)
        http.on("/calendar/v3/calendars", body: #"{"id":"cal1"}"#)
        http.on("/calendars/cal1/events", body: "{}")
        await sync.sync(now: now)
        XCTAssertNil(sync.error, "\(String(describing: sync.error))")
        let eventPosts = http.requests.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/events") }
        XCTAssertEqual(eventPosts.count, 1)
        let body = try XCTUnwrap(eventPosts.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["summary"] as? String, "At Costa Coffee · £3.40")

        // Second sync with nothing new: verifies the calendar, writes nothing.
        let before = http.requests.count
        http.on("/calendars/cal1", body: #"{"id":"cal1"}"#)
        await sync.sync(now: now)
        XCTAssertEqual(http.requests.count, before + 1, "Only the calendar check, no event writes")

        // A second purchase arrives: the same event is updated (POST conflicts, then PUT), not duplicated.
        try transactions.apply([coffee("t2", 250)], refreshedAccountIDs: [])
        http.on("/calendars/cal1", body: #"{"id":"cal1"}"#)
        http.on("/calendars/cal1/events", status: 409, body: #"{"error":{"code":409,"message":"exists"}}"#)
        http.on("/events/\(CalendarEventID.forVisit(visit.id))", body: "{}")
        await sync.sync(now: now)
        XCTAssertNil(sync.error)
        XCTAssertEqual(http.requests.last?.httpMethod, "PUT")
        let put = try XCTUnwrap(http.requests.last?.httpBody)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: put) as? [String: Any])
        XCTAssertEqual(updated["summary"] as? String, "At Costa Coffee · £5.90")
    }

    func testDoesNothingWhenCalendarWritingIsOff() async throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let store = InMemorySecureStore()
        try store.setValue(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture), for: SecureStoreKey.googleTokens)
        let http = StubHTTPClient()
        let auth = GoogleAuthService(configuration: GoogleOAuthConfiguration(clientID: "1-x.apps.googleusercontent.com"), store: store, http: http)
        let sync = CalendarSyncService(auth: auth, client: GoogleCalendarClient(tokens: auth, http: http),
                                       visits: VisitRepository(container: container), transactions: TransactionRepository(container: container),
                                       settings: AppSettings(defaults: defaults), defaults: defaults)
        await sync.sync()
        XCTAssertTrue(http.requests.isEmpty)
    }
}
