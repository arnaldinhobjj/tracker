import AIKit
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
        settings.calendarDestination = .google
        let sync = CalendarSyncService(google: GoogleCalendarDestination(auth: auth, client: GoogleCalendarClient(tokens: auth, http: http)),
                                       apple: EventKitCalendarDestination(store: InMemoryEventStore()), visits: visits,
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
        let settings = AppSettings(defaults: defaults)
        settings.calendarDestination = .google
        let sync = CalendarSyncService(google: GoogleCalendarDestination(auth: auth, client: GoogleCalendarClient(tokens: auth, http: http)),
                                       apple: EventKitCalendarDestination(store: InMemoryEventStore(access: .granted)),
                                       visits: VisitRepository(container: container), transactions: TransactionRepository(container: container),
                                       settings: settings, defaults: defaults)
        await sync.sync()
        XCTAssertTrue(http.requests.isEmpty)
    }
}

/// Apple Calendar (EventKit), the default destination, against an in-memory event store.
@MainActor
final class AppleCalendarSyncTests: XCTestCase {
    private struct Harness {
        let sync: CalendarSyncService
        let store: InMemoryEventStore
        let visits: VisitRepository
        let transactions: TransactionRepository
        let settings: AppSettings
        let http: StubHTTPClient
    }

    private func makeHarness(access: EventAccess = .granted) -> Harness {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.calendarWritingEnabled = true
        let store = InMemoryEventStore(access: access)
        let http = StubHTTPClient()
        let auth = GoogleAuthService(configuration: GoogleOAuthConfiguration(clientID: "1-x.apps.googleusercontent.com"),
                                     store: InMemorySecureStore(), http: http)
        let visits = VisitRepository(container: container)
        let transactions = TransactionRepository(container: container)
        let sync = CalendarSyncService(google: GoogleCalendarDestination(auth: auth, client: GoogleCalendarClient(tokens: auth, http: http)),
                                       apple: EventKitCalendarDestination(store: store), visits: visits, transactions: transactions,
                                       settings: settings, defaults: defaults)
        return Harness(sync: sync, store: store, visits: visits, transactions: transactions, settings: settings, http: http)
    }

    private func recordCoffeeVisit(_ h: Harness, pence: Int, id: String = "t1") throws -> StoredVisit {
        let now = Date()
        let arrival = now.addingTimeInterval(-3_600)
        let visit = try XCTUnwrap(h.visits.record(VisitEvent(arrival: arrival, departure: now.addingTimeInterval(-1_800), latitude: 51.5,
                                                             longitude: -0.12, horizontalAccuracy: 20)))
        try h.visits.applyPlace(ResolvedPlace(name: "Costa Coffee", category: "MKPOICategoryCafe", isPointOfInterest: true), to: visit)
        try h.transactions.apply([BankTransaction(id: id, accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA", amountMinor: pence,
                                                  direction: .debit, bankCategory: "PURCHASE", category: .coffee,
                                                  timestamp: arrival.addingTimeInterval(300), hasTime: true, isPending: false)],
                                 refreshedAccountIDs: [])
        return visit
    }

    func testNewUsersWriteToAppleCalendar() {
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        XCTAssertEqual(fresh.calendarDestination, .apple)
    }

    func testExistingGoogleWritersStayOnGoogle() {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        // Written by a version before Apple Calendar: calendar writing on, no destination saved.
        defaults.set(true, forKey: "settings.calendarWriting")
        XCTAssertEqual(AppSettings(defaults: defaults).calendarDestination, .google)
        XCTAssertEqual(defaults.string(forKey: "settings.calendarDestination"), "google", "Saved, so it never flips")
    }

    func testWritesOnceThenUpdatesTheSameEvent() async throws {
        let h = makeHarness()
        _ = try recordCoffeeVisit(h, pence: 340)

        await h.sync.sync()

        XCTAssertNil(h.sync.error, "\(String(describing: h.sync.error))")
        XCTAssertEqual(h.store.calendars.values.map(\.title), ["DayLedger"], "Created its own calendar")
        XCTAssertEqual(h.store.events.count, 1)
        XCTAssertEqual(h.store.events.values.first?.fields.title, "At Costa Coffee · £3.40")
        XCTAssertTrue(h.http.requests.isEmpty, "Nothing goes to Google")
        XCTAssertEqual(h.sync.lastResult, "Updated 1 event", "Singular from the String Catalog")

        // Re-syncing writes nothing; a new purchase updates the same event.
        await h.sync.sync()
        XCTAssertEqual(h.store.events.count, 1)
        try h.transactions.apply([BankTransaction(id: "t2", accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA", amountMinor: 250,
                                                  direction: .debit, bankCategory: "PURCHASE", category: .coffee,
                                                  timestamp: Date().addingTimeInterval(-3_000), hasTime: true, isPending: false)],
                                 refreshedAccountIDs: [])
        await h.sync.sync()
        XCTAssertEqual(h.store.events.count, 1, "Updated, not duplicated")
        XCTAssertEqual(h.store.events.values.first?.fields.title, "At Costa Coffee · £5.90")
    }

    func testFindsItsCalendarAndEventsAgainAfterAReinstall() async throws {
        let h = makeHarness()
        _ = try recordCoffeeVisit(h, pence: 340)
        await h.sync.sync()
        let calendarID = try XCTUnwrap(h.store.calendars.keys.first)

        // Reinstall: the remembered calendar ID and the visits' write records are gone.
        h.sync.forgetCalendar()
        h.visits.resetSyncState()
        await h.sync.sync()

        XCTAssertEqual(Array(h.store.calendars.keys), [calendarID], "Found by title, not recreated")
        XCTAssertEqual(h.store.events.count, 1, "Found by its dayledger:// URL, not duplicated")
    }

    func testWithoutFullAccessNothingIsWritten() async throws {
        for access in [EventAccess.notDetermined, .writeOnly, .denied] {
            let h = makeHarness(access: access)
            _ = try recordCoffeeVisit(h, pence: 340)
            await h.sync.sync()
            XCTAssertTrue(h.store.calendars.isEmpty)
            do {
                _ = try await h.sync.createEvents(for: [EventProposal(id: "p", title: "Gym", start: Date().addingTimeInterval(86_400),
                                                                      durationMinutes: 60, reason: "r", confidence: .high)])
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? CalendarError, .calendarAccessDenied)
            }
        }
    }

    func testSwitchingCalendarsRewritesRecentVisitsToTheNewOne() async throws {
        let h = makeHarness()
        let visit = try recordCoffeeVisit(h, pence: 340)
        h.settings.calendarDestination = .google
        h.visits.markSynced(visit, eventID: "x", hash: "written-to-google")

        h.sync.switchDestination(to: .apple)
        await h.sync.sync()

        XCTAssertEqual(h.settings.calendarDestination, .apple)
        XCTAssertEqual(h.store.events.count, 1, "The visit is written to Apple Calendar too")
    }

    /// The user switches to Apple Calendar while a Google sync is waiting on the network: during
    /// calendar discovery, or while an event is being written.
    func testSwitchingCalendarsDuringASyncWritesToTheNewCalendar() async throws {
        for stage in [SwitchingDestination.Stage.findingCalendar, .writingEvent] {
            let h = makeHarness()
            _ = try recordCoffeeVisit(h, pence: 340)
            let google = SwitchingDestination(switchDuring: stage)
            let sync = CalendarSyncService(google: google, apple: EventKitCalendarDestination(store: h.store), visits: h.visits,
                                           transactions: h.transactions, settings: h.settings, defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
            h.settings.calendarDestination = .google
            google.onSwitchPoint = { sync.switchDestination(to: .apple) }

            await sync.sync()

            XCTAssertEqual(h.settings.calendarDestination, .apple, "\(stage)")
            XCTAssertEqual(h.store.events.count, 1, "\(stage): the visit isn't skipped in the newly chosen calendar")
            let appleCalendar = try XCTUnwrap(h.store.calendars.keys.first, "\(stage)")
            XCTAssertEqual(sync.calendarID, appleCalendar, "\(stage): Google's calendar ID isn't saved as Apple's")
            XCTAssertNil(sync.error, "\(stage)")
            XCTAssertFalse(sync.isSyncing)
        }
    }

    func testApprovedSuggestionsAreWrittenOnce() async throws {
        let h = makeHarness()
        let proposal = EventProposal(id: "gym|1", title: "Gym", start: Date().addingTimeInterval(86_400), durationMinutes: 60,
                                     reason: "Most Tuesdays", confidence: .high)
        _ = try await h.sync.createEvents(for: [proposal])
        _ = try await h.sync.createEvents(for: [proposal])
        XCTAssertEqual(h.store.events.count, 1)
        XCTAssertEqual(h.store.events.values.first?.fields.isBusy, true)
    }

    func testBusyTimesComeFromAllCalendars() async {
        let h = makeHarness()
        let meeting = DateInterval(start: Date().addingTimeInterval(3_600), duration: 1_800)
        h.store.otherBusy = [meeting]
        let busy = await h.sync.busyIntervals(from: Date(), to: Date().addingTimeInterval(86_400))
        XCTAssertEqual(busy, [meeting])
    }
}

/// A Google-like destination that calls `onSwitchPoint` (to switch calendars) while it is
/// "waiting on the network" at the given stage.
@MainActor
private final class SwitchingDestination: CalendarDestination {
    enum Stage { case findingCalendar, writingEvent }

    let kind = CalendarDestinationKind.google
    let isConfigured = true
    let isAuthorized = true
    let stage: Stage
    var onSwitchPoint: (() -> Void)?
    private(set) var upserts = 0

    init(switchDuring stage: Stage) {
        self.stage = stage
    }

    func ensureDayLedgerCalendar(knownID: String?) async throws -> String {
        if stage == .findingCalendar { onSwitchPoint?() }
        return "google-calendar"
    }

    func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws {
        upserts += 1
        if stage == .writingEvent { onSwitchPoint?() }
    }

    func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] { [] }
    func deleteCalendar(id: String) async throws {}
}
