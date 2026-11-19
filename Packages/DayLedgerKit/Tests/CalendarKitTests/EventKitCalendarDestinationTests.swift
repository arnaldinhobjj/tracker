import XCTest
@testable import CalendarKit

@MainActor
final class EventKitCalendarDestinationTests: XCTestCase {
    private func draft(_ id: String = "dlv1", title: String = "At Costa", start: Date = Date(timeIntervalSince1970: 1_000_000)) -> CalendarEventDraft {
        CalendarEventDraft(id: id, summary: title, description: "£3.40", start: start, end: start.addingTimeInterval(1_800),
                           timeZone: TimeZone(identifier: "Europe/London")!, location: "Costa Coffee", privateProperties: [:], showsAsBusy: false)
    }

    func testAccessIsRequestedOnceAndOnlyFullAccessCounts() async throws {
        let store = InMemoryEventStore(access: .notDetermined)
        let destination = EventKitCalendarDestination(store: store)
        XCTAssertFalse(destination.isAuthorized)
        XCTAssertTrue(try await destination.requestAccess())
        XCTAssertTrue(destination.isAuthorized)

        XCTAssertFalse(EventKitCalendarDestination(store: InMemoryEventStore(access: .writeOnly)).isAuthorized,
                       "Write-only access can't update events, so it isn't enough")
        let refusing = InMemoryEventStore(access: .notDetermined, grantsAccessOnRequest: false)
        XCTAssertFalse(try await EventKitCalendarDestination(store: refusing).requestAccess())
    }

    func testCalendarIsCreatedOnceThenReused() async throws {
        let store = InMemoryEventStore(access: .granted)
        let destination = EventKitCalendarDestination(store: store)

        let created = try await destination.ensureDayLedgerCalendar(knownID: nil)
        XCTAssertEqual(store.calendars[created]?.title, "DayLedger")
        let again = try await destination.ensureDayLedgerCalendar(knownID: created)
        XCTAssertEqual(again, created)
        let found = try await destination.ensureDayLedgerCalendar(knownID: "deleted-id")
        XCTAssertEqual(found, created, "Found by title when the remembered one is gone")
        XCTAssertEqual(store.calendars.count, 1)
    }

    func testAReadOnlyCalendarWithTheSameTitleIsNotUsed() async throws {
        let store = InMemoryEventStore(access: .granted)
        let readOnly = store.addCalendar(titled: "DayLedger", isWritable: false)
        let id = try await EventKitCalendarDestination(store: store).ensureDayLedgerCalendar(knownID: nil)
        XCTAssertNotEqual(id, readOnly)
    }

    func testUpsertIsIdempotentAndMarksEvents() async throws {
        let store = InMemoryEventStore(access: .granted)
        let destination = EventKitCalendarDestination(store: store)
        let calendar = try await destination.ensureDayLedgerCalendar(knownID: nil)

        try await destination.upsert(draft(), calendarID: calendar)
        try await destination.upsert(draft(title: "At Costa (updated)"), calendarID: calendar)
        try await destination.upsert(draft("dlv2"), calendarID: calendar)

        XCTAssertEqual(store.events.count, 2)
        let first = try XCTUnwrap(store.events.values.first { $0.fields.url == EventKitCalendarDestination.marker(for: "dlv1") })
        XCTAssertEqual(first.fields.title, "At Costa (updated)")
        XCTAssertEqual(first.fields.location, "Costa Coffee")
        XCTAssertFalse(first.fields.isBusy, "Visits are logged as free time")
        XCTAssertEqual(EventKitCalendarDestination.marker(for: "dlv1").absoluteString, "dayledger://event/dlv1")
    }

    func testNothingIsWrittenWithoutAccess() async {
        let store = InMemoryEventStore(access: .denied)
        let destination = EventKitCalendarDestination(store: store)
        do {
            _ = try await destination.ensureDayLedgerCalendar(knownID: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CalendarError, .calendarAccessDenied)
        }
        let busy = try? await destination.busyIntervals(from: Date(), to: Date().addingTimeInterval(3_600))
        XCTAssertEqual(busy, [])
        XCTAssertTrue(store.calendars.isEmpty)
    }

    func testDeletingTheCalendarRemovesItsEvents() async throws {
        let store = InMemoryEventStore(access: .granted)
        let destination = EventKitCalendarDestination(store: store)
        let calendar = try await destination.ensureDayLedgerCalendar(knownID: nil)
        try await destination.upsert(draft(), calendarID: calendar)

        try await destination.deleteCalendar(id: calendar)

        XCTAssertTrue(store.calendars.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
    }
}
