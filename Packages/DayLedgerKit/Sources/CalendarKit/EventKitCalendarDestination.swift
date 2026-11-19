import EventKit
import Foundation

/// Calendar permission, as DayLedger needs it.
public enum EventAccess: Equatable, Sendable {
    case notDetermined
    /// Full access: needed to create the DayLedger calendar and update its events.
    case granted
    /// Write-only access (iOS 17): can add events but not find or update them, so DayLedger would
    /// duplicate visits. Treated as not enough.
    case writeOnly
    case denied
}

/// A calendar event DayLedger wrote, as stored.
public struct StoredEventRef: Equatable, Sendable {
    public var identifier: String
    public var url: URL?

    public init(identifier: String, url: URL?) {
        self.identifier = identifier
        self.url = url
    }
}

/// What DayLedger writes into an event.
public struct EventFields: Equatable, Sendable {
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var timeZone: TimeZone
    public var location: String?
    /// `dayledger://event/<id>`: how the event is found again (no stored identifiers needed).
    public var url: URL
    public var isBusy: Bool

    public init(title: String, notes: String, start: Date, end: Date, timeZone: TimeZone, location: String?, url: URL, isBusy: Bool) {
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.location = location
        self.url = url
        self.isBusy = isBusy
    }
}

/// The parts of EventKit DayLedger uses. `SystemEventStore` is the real one; `InMemoryEventStore`
/// is for tests, previews and UI tests (EventKit permission can't be granted in CI).
@MainActor
public protocol EventStoring: AnyObject {
    var access: EventAccess { get }
    /// Asks for full access (shows the system prompt once). Returns whether it was granted.
    func requestAccess() async throws -> Bool
    func calendarExists(id: String) -> Bool
    /// A calendar DayLedger can write to with this title (to find the calendar again after a reinstall).
    func writableCalendarID(titled title: String) -> String?
    func createCalendar(titled title: String) throws -> String
    func deleteCalendar(id: String) throws
    func events(inCalendar id: String, from start: Date, to end: Date) -> [StoredEventRef]
    /// Saves `fields` into the calendar, updating the event `identifier` if it still exists.
    func saveEvent(_ fields: EventFields, replacing identifier: String?, inCalendar id: String) throws
    /// Busy times across all calendars (timed events not marked free).
    func busyIntervals(from start: Date, to end: Date) -> [DateInterval]
}

/// Apple Calendar: writes to a "DayLedger" calendar on the iPhone (iCloud when available).
@MainActor
public final class EventKitCalendarDestination: CalendarDestination {
    public let kind = CalendarDestinationKind.apple
    public static let calendarTitle = GoogleCalendarClient.calendarName
    /// Events are looked for within this distance of a draft's times.
    static let searchMargin: TimeInterval = 2 * 86_400

    private let store: EventStoring

    public init(store: EventStoring) {
        self.store = store
    }

    public var isConfigured: Bool { true }
    public var isAuthorized: Bool { store.access == .granted }
    public var access: EventAccess { store.access }

    @discardableResult
    public func requestAccess() async throws -> Bool {
        try await store.requestAccess()
    }

    public func ensureDayLedgerCalendar(knownID: String?) async throws -> String {
        guard isAuthorized else { throw CalendarError.calendarAccessDenied }
        if let knownID, store.calendarExists(id: knownID) { return knownID }
        if let existing = store.writableCalendarID(titled: Self.calendarTitle) { return existing }
        return try store.createCalendar(titled: Self.calendarTitle)
    }

    /// Finds the event by its `dayledger://event/<id>` URL near the draft's time and updates it,
    /// or creates it. Running this twice for the same draft never creates a duplicate.
    public func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws {
        guard isAuthorized else { throw CalendarError.calendarAccessDenied }
        guard store.calendarExists(id: calendarID) else { throw CalendarError.calendarNotFound }
        let marker = Self.marker(for: draft.id)
        let existing = store.events(inCalendar: calendarID, from: draft.start.addingTimeInterval(-Self.searchMargin),
                                    to: draft.end.addingTimeInterval(Self.searchMargin))
            .first { $0.url == marker }
        let fields = EventFields(title: draft.summary, notes: draft.description, start: draft.start, end: draft.end,
                                 timeZone: draft.timeZone, location: draft.location, url: marker, isBusy: draft.showsAsBusy)
        try store.saveEvent(fields, replacing: existing?.identifier, inCalendar: calendarID)
    }

    public func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] {
        guard isAuthorized else { return [] }
        return store.busyIntervals(from: start, to: end)
    }

    public func deleteCalendar(id: String) async throws {
        guard isAuthorized, store.calendarExists(id: id) else { return }
        try store.deleteCalendar(id: id)
    }

    public static func marker(for eventID: String) -> URL {
        // Event IDs are sanitised to base32hex (CalendarEventID), so they are always URL-safe.
        URL(string: "dayledger://event/\(eventID)")!
    }
}

/// EventKit itself.
@MainActor
public final class SystemEventStore: EventStoring {
    private let store = EKEventStore()

    public init() {}

    public var access: EventAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return .granted }
        if status == .writeOnly { return .writeOnly }
        if status == .notDetermined { return .notDetermined }
        return .denied
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendarExists(id: String) -> Bool {
        store.calendar(withIdentifier: id) != nil
    }

    public func writableCalendarID(titled title: String) -> String? {
        store.calendars(for: .event).first { $0.title == title && $0.allowsContentModifications }?.calendarIdentifier
    }

    /// Prefers the account new events go to (usually iCloud), then iCloud, then a local calendar.
    public func createCalendar(titled title: String) throws -> String {
        var candidates: [EKSource] = []
        if let source = store.defaultCalendarForNewEvents?.source { candidates.append(source) }
        candidates += store.sources.filter { $0.sourceType == .calDAV && $0.title == "iCloud" }
        candidates += store.sources.filter { $0.sourceType == .local }
        var lastError: Error = CalendarError.calendarNotFound
        for source in candidates {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                return calendar.calendarIdentifier
            } catch {
                // Some accounts (e.g. Exchange) don't allow new calendars: try the next.
                lastError = error
            }
        }
        throw lastError
    }

    public func deleteCalendar(id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(calendar, commit: true)
    }

    public func events(inCalendar id: String, from start: Date, to end: Date) -> [StoredEventRef] {
        guard let calendar = store.calendar(withIdentifier: id) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).map { StoredEventRef(identifier: $0.eventIdentifier, url: $0.url) }
    }

    public func saveEvent(_ fields: EventFields, replacing identifier: String?, inCalendar id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { throw CalendarError.calendarNotFound }
        let event = identifier.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = fields.title
        event.notes = fields.notes
        event.startDate = fields.start
        event.endDate = fields.end
        event.timeZone = fields.timeZone
        event.location = fields.location
        event.url = fields.url
        event.availability = fields.isBusy ? .busy : .free
        try store.save(event, span: .thisEvent, commit: true)
    }

    public func busyIntervals(from start: Date, to end: Date) -> [DateInterval] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }
}

/// In-memory calendars for tests, previews and UI tests.
@MainActor
public final class InMemoryEventStore: EventStoring {
    public struct CalendarRecord: Equatable {
        public var title: String
        public var isWritable: Bool
    }

    public struct EventRecord: Equatable {
        public var calendarID: String
        public var fields: EventFields
    }

    public var access: EventAccess
    /// What `requestAccess` does when not determined yet.
    public var grantsAccessOnRequest: Bool
    public private(set) var calendars: [String: CalendarRecord] = [:]
    public private(set) var events: [String: EventRecord] = [:]
    /// Busy times in the user's other calendars.
    public var otherBusy: [DateInterval] = []
    private var nextID = 0

    public init(access: EventAccess = .notDetermined, grantsAccessOnRequest: Bool = true) {
        self.access = access
        self.grantsAccessOnRequest = grantsAccessOnRequest
    }

    @discardableResult
    public func addCalendar(titled title: String, isWritable: Bool = true) -> String {
        let id = makeID("cal")
        calendars[id] = CalendarRecord(title: title, isWritable: isWritable)
        return id
    }

    public func requestAccess() async throws -> Bool {
        if access == .notDetermined { access = grantsAccessOnRequest ? .granted : .denied }
        return access == .granted
    }

    public func calendarExists(id: String) -> Bool { calendars[id] != nil }

    public func writableCalendarID(titled title: String) -> String? {
        calendars.filter { $0.value.title == title && $0.value.isWritable }.keys.sorted().first
    }

    public func createCalendar(titled title: String) throws -> String {
        addCalendar(titled: title)
    }

    public func deleteCalendar(id: String) throws {
        calendars[id] = nil
        events = events.filter { $0.value.calendarID != id }
    }

    public func events(inCalendar id: String, from start: Date, to end: Date) -> [StoredEventRef] {
        events.filter { $0.value.calendarID == id && $0.value.fields.start < end && $0.value.fields.end > start }
            .map { StoredEventRef(identifier: $0.key, url: $0.value.fields.url) }
            .sorted { $0.identifier < $1.identifier }
    }

    public func saveEvent(_ fields: EventFields, replacing identifier: String?, inCalendar id: String) throws {
        guard calendars[id] != nil else { throw CalendarError.calendarNotFound }
        let key = identifier.flatMap { events[$0] != nil ? $0 : nil } ?? makeID("evt")
        events[key] = EventRecord(calendarID: id, fields: fields)
    }

    public func busyIntervals(from start: Date, to end: Date) -> [DateInterval] {
        let own = events.values.filter { $0.fields.isBusy && $0.fields.start < end && $0.fields.end > start }
            .map { DateInterval(start: $0.fields.start, end: $0.fields.end) }
        return (own + otherBusy.filter { $0.start < end && $0.end > start }).sorted { $0.start < $1.start }
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)-\(nextID)"
    }
}
