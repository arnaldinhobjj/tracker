import AIKit
import CalendarKit
import Foundation
import Observation
import SharedModels

/// Writes completed visits (with matched spending) to the dedicated DayLedger calendar, in Apple
/// Calendar (default) or Google Calendar. Idempotent: events are identified by IDs derived from
/// visit IDs, and unchanged events are skipped.
@MainActor
@Observable
final class CalendarSyncService {
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastResult: String?
    var error: UserFacingError?

    @ObservationIgnored private let google: CalendarDestination
    @ObservationIgnored private let apple: CalendarDestination
    @ObservationIgnored private let visits: VisitRepository
    @ObservationIgnored private let transactions: TransactionRepository
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let matcher = VisitTransactionMatcher()
    @ObservationIgnored private let builder = VisitEventBuilder()

    /// How far back visits are (re)written. Older ones are left alone.
    static let syncWindow: TimeInterval = 7 * 24 * 3600

    init(google: CalendarDestination, apple: CalendarDestination, visits: VisitRepository, transactions: TransactionRepository,
         settings: AppSettings, defaults: UserDefaults) {
        self.google = google
        self.apple = apple
        self.visits = visits
        self.transactions = transactions
        self.settings = settings
        self.defaults = defaults
    }

    /// The calendar chosen in Settings.
    var destination: CalendarDestination {
        settings.calendarDestination == .apple ? apple : google
    }

    var isAuthorized: Bool { destination.isAuthorized }
    var isConfigured: Bool { destination.isConfigured }

    /// The DayLedger calendar's ID in each destination. (Google keeps the key used before Apple
    /// Calendar existed.)
    private func calendarIDKey(_ kind: CalendarDestinationKind) -> String {
        kind == .google ? "calendar.dayledgerCalendarID" : "calendar.apple.calendarID"
    }

    var calendarID: String? {
        get { defaults.string(forKey: calendarIDKey(destination.kind)) }
        set { defaults.set(newValue, forKey: calendarIDKey(destination.kind)) }
    }

    /// Switches calendars. Visits' write records describe the previous calendar, so they are reset
    /// and recent visits are written to the new one on the next sync.
    func switchDestination(to kind: CalendarDestinationKind) {
        guard settings.calendarDestination != kind else { return }
        settings.calendarDestination = kind
        visits.resetSyncState()
        lastResult = nil
        error = nil
    }

    func sync(now: Date = Date()) async {
        guard settings.calendarWritingEnabled, destination.isAuthorized, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let since = now.addingTimeInterval(-Self.syncWindow)
        let stored = visits.visits(since: since).filter { visit in
            guard let departure = visit.departure, visit.isResolved else { return false }
            if settings.onlyNamedPlaces && !visit.isNamedPlace { return false }
            return departure.timeIntervalSince(visit.arrival) >= TimeInterval(settings.minimumVisitMinutes * 60)
        }
        guard !stored.isEmpty else {
            lastSync = now
            error = nil
            return
        }

        let spend = transactions.transactions(from: since.addingTimeInterval(-24 * 3600), to: now.addingTimeInterval(3600))
        let matches = matcher.match(visits: stored.map(\.domain), transactions: spend, now: now)

        var written = 0
        do {
            let calendarID = try await destination.ensureDayLedgerCalendar(knownID: self.calendarID)
            if calendarID != self.calendarID {
                // New or recreated calendar: previous sync records point at nothing.
                if self.calendarID != nil { visits.resetSyncState() }
                self.calendarID = calendarID
            }
            for visit in stored {
                guard let draft = builder.draft(for: visit.domain, matches: matches[visit.id] ?? []) else { continue }
                let hash = draft.contentHash
                if visit.calendarContentHash == hash { continue }
                try await destination.upsert(draft, calendarID: calendarID)
                visits.markSynced(visit, eventID: draft.id, hash: hash, at: now)
                written += 1
            }
            lastSync = now
            lastResult = written == 0 ? "Up to date" : "Updated \(written) event\(written == 1 ? "" : "s")"
            error = nil
        } catch {
            // Whatever wasn't written keeps its old hash and is retried on the next sync.
            self.error = UserFacingError(error)
        }
    }

    /// Busy times (no titles or details). Empty without access.
    func busyIntervals(from start: Date, to end: Date) async -> [DateInterval] {
        guard destination.isAuthorized else { return [] }
        return (try? await destination.busyIntervals(from: start, to: end)) ?? []
    }

    /// Writes user-approved AI suggestions to the DayLedger calendar. Event IDs come from the
    /// proposal, so approving the same suggestion twice doesn't create two events.
    func createEvents(for proposals: [EventProposal], timeZone: TimeZone = .current) async throws -> Int {
        guard destination.isAuthorized else {
            throw destination.kind == .google ? CalendarError.notSignedIn : CalendarError.calendarAccessDenied
        }
        let calendarID = try await destination.ensureDayLedgerCalendar(knownID: self.calendarID)
        self.calendarID = calendarID
        var created = 0
        for proposal in proposals {
            let draft = CalendarEventDraft(
                id: CalendarEventID.forSuggestion(key: proposal.id),
                summary: proposal.title,
                description: [proposal.reason, "", "Suggested by DayLedger's AI assistant and approved by you."].joined(separator: "\n"),
                start: proposal.start,
                end: proposal.end,
                timeZone: timeZone,
                privateProperties: ["dayledgerKind": "suggestion"],
                showsAsBusy: true
            )
            try await destination.upsert(draft, calendarID: calendarID)
            created += 1
        }
        return created
    }

    /// Deletes the DayLedger calendar from every destination DayLedger can still reach ("Delete
    /// all my data"). Returns the failures, by destination.
    func deleteCalendars() async -> [String] {
        var failures: [String] = []
        for destination in [apple, google] where destination.isAuthorized {
            guard let id = defaults.string(forKey: calendarIDKey(destination.kind)) else { continue }
            do {
                try await destination.deleteCalendar(id: id)
            } catch {
                failures.append("\(destination.kind.displayName): \(UserFacingError(error).message)")
            }
        }
        forgetCalendar()
        visits.resetSyncState()
        return failures
    }

    func forgetCalendar() {
        for kind in CalendarDestinationKind.allCases {
            defaults.removeObject(forKey: calendarIDKey(kind))
        }
    }
}
