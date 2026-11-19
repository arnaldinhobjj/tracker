import Foundation

/// Which calendar DayLedger writes to.
public enum CalendarDestinationKind: String, CaseIterable, Sendable {
    /// The calendars on the iPhone (iCloud, or any account added in Settings), via EventKit.
    /// The default: no sign-in, no OAuth project, no Google verification.
    case apple
    /// Google Calendar through its API (optional; needs a Google OAuth client).
    case google

    public var displayName: String {
        switch self {
        case .apple: return "Apple Calendar"
        case .google: return "Google Calendar"
        }
    }
}

/// Where visits and approved AI suggestions are written. Both destinations keep DayLedger's events
/// in a dedicated "DayLedger" calendar and are idempotent: writing the same draft twice updates
/// the event instead of creating a second one.
@MainActor
public protocol CalendarDestination: AnyObject {
    var kind: CalendarDestinationKind { get }
    /// The build has what this destination needs (e.g. a Google client ID).
    var isConfigured: Bool { get }
    /// Signed in (Google) or granted full calendar access (Apple).
    var isAuthorized: Bool { get }
    /// Returns the DayLedger calendar's ID, finding or creating it. `knownID` is checked first.
    func ensureDayLedgerCalendar(knownID: String?) async throws -> String
    func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws
    /// Times the user is busy (no titles or details).
    func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval]
    func deleteCalendar(id: String) async throws
}

/// Google Calendar, through `GoogleCalendarClient`.
@MainActor
public final class GoogleCalendarDestination: CalendarDestination {
    public let kind = CalendarDestinationKind.google
    private let auth: GoogleAuthService
    private let client: GoogleCalendarClient

    public init(auth: GoogleAuthService, client: GoogleCalendarClient) {
        self.auth = auth
        self.client = client
    }

    public var isConfigured: Bool { auth.isConfigured }
    public var isAuthorized: Bool { auth.isSignedIn }

    public func ensureDayLedgerCalendar(knownID: String?) async throws -> String {
        try await client.ensureDayLedgerCalendar(knownID: knownID)
    }

    public func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws {
        try await client.upsert(draft, calendarID: calendarID)
    }

    public func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] {
        try await client.busyIntervals(from: start, to: end)
    }

    public func deleteCalendar(id: String) async throws {
        try await client.deleteCalendar(id: id)
    }
}
