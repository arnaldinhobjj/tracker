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
    /// Bumped on every calendar switch. A sync that started before a switch stops at its next
    /// step instead of recording writes (or a calendar ID) against the newly chosen calendar.
    @ObservationIgnored private var destinationGeneration = 0

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
        get { storedCalendarID(for: destination.kind) }
        set { storeCalendarID(newValue, for: destination.kind) }
    }

    private func storedCalendarID(for kind: CalendarDestinationKind) -> String? {
        defaults.string(forKey: calendarIDKey(kind))
    }

    private func storeCalendarID(_ id: String?, for kind: CalendarDestinationKind) {
        defaults.set(id, forKey: calendarIDKey(kind))
    }

    /// Switches calendars. Visits' write records describe the previous calendar, so they are reset
    /// and recent visits are written to the new one on the next sync.
    func switchDestination(to kind: CalendarDestinationKind) {
        guard settings.calendarDestination != kind else { return }
        settings.calendarDestination = kind
        destinationGeneration += 1
        visits.resetSyncState()
        lastResult = nil
        error = nil
    }

    func sync(now: Date = Date()) async {
        guard settings.calendarWritingEnabled, destination.isAuthorized, !isSyncing else { return }
        isSyncing = true
        let generation = destinationGeneration
        await syncOnce(to: destination, generation: generation, now: now)
        isSyncing = false
        // The calendar was switched while this sync ran: write recent visits to the new one now.
        if destinationGeneration != generation {
            await sync(now: Date())
        }
    }

    /// Whether the calendar is still the one this sync started with.
    private func isCurrent(_ generation: Int) -> Bool { destinationGeneration == generation }

    private func syncOnce(to target: CalendarDestination, generation: Int, now: Date) async {
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
            let knownID = storedCalendarID(for: target.kind)
            let calendarID = try await target.ensureDayLedgerCalendar(knownID: knownID)
            guard isCurrent(generation) else { return }
            if calendarID != knownID {
                // New or recreated calendar: previous sync records point at nothing.
                if knownID != nil { visits.resetSyncState() }
                storeCalendarID(calendarID, for: target.kind)
            }
            for visit in stored {
                guard let draft = builder.draft(for: visit.domain, matches: matches[visit.id] ?? []) else { continue }
                let hash = draft.contentHash
                if visit.calendarContentHash == hash { continue }
                try await target.upsert(draft, calendarID: calendarID)
                // Written to the calendar that was just replaced: don't record it as written.
                guard isCurrent(generation) else { return }
                visits.markSynced(visit, eventID: draft.id, hash: hash, at: now)
                written += 1
            }
            lastSync = now
            // Plural forms come from the String Catalog ("Updated %lld events").
            lastResult = written == 0 ? String(localized: "Up to date") : String(localized: "Updated \(written) events")
            error = nil
        } catch {
            // Whatever wasn't written keeps its old hash and is retried on the next sync.
            guard isCurrent(generation) else { return }
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
        let target = destination
        guard target.isAuthorized else {
            throw target.kind == .google ? CalendarError.notSignedIn : CalendarError.calendarAccessDenied
        }
        let calendarID = try await target.ensureDayLedgerCalendar(knownID: storedCalendarID(for: target.kind))
        storeCalendarID(calendarID, for: target.kind)
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
            try await target.upsert(draft, calendarID: calendarID)
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
