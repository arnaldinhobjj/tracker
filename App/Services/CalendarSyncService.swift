import CalendarKit
import Foundation
import Observation
import SharedModels

/// Writes completed visits (with matched spending) to the dedicated DayLedger Google calendar.
/// Idempotent: event IDs are derived from visit IDs, and unchanged events are skipped.
@MainActor
@Observable
final class CalendarSyncService {
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastResult: String?
    var error: UserFacingError?

    @ObservationIgnored private let auth: GoogleAuthService
    @ObservationIgnored private let client: GoogleCalendarClient
    @ObservationIgnored private let visits: VisitRepository
    @ObservationIgnored private let transactions: TransactionRepository
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let matcher = VisitTransactionMatcher()
    @ObservationIgnored private let builder = VisitEventBuilder()
    private let calendarIDKey = "calendar.dayledgerCalendarID"

    /// How far back visits are (re)written. Older ones are left alone.
    static let syncWindow: TimeInterval = 7 * 24 * 3600

    init(auth: GoogleAuthService, client: GoogleCalendarClient, visits: VisitRepository, transactions: TransactionRepository,
         settings: AppSettings, defaults: UserDefaults) {
        self.auth = auth
        self.client = client
        self.visits = visits
        self.transactions = transactions
        self.settings = settings
        self.defaults = defaults
    }

    var isSignedIn: Bool { auth.isSignedIn }
    var isConfigured: Bool { auth.isConfigured }

    var calendarID: String? {
        get { defaults.string(forKey: calendarIDKey) }
        set { defaults.set(newValue, forKey: calendarIDKey) }
    }

    func sync(now: Date = Date()) async {
        guard settings.calendarWritingEnabled, auth.isSignedIn, !isSyncing else { return }
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
            let calendarID = try await client.ensureDayLedgerCalendar(knownID: self.calendarID)
            if calendarID != self.calendarID {
                // New or recreated calendar: previous sync records point at nothing.
                if self.calendarID != nil { visits.resetSyncState() }
                self.calendarID = calendarID
            }
            for visit in stored {
                guard let draft = builder.draft(for: visit.domain, matches: matches[visit.id] ?? []) else { continue }
                let hash = draft.contentHash
                if visit.calendarContentHash == hash { continue }
                try await client.upsert(draft, calendarID: calendarID)
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

    /// Deletes the DayLedger calendar from Google (used by "Delete all my data").
    func deleteCalendar() async throws {
        guard let calendarID else { return }
        try await client.deleteCalendar(id: calendarID)
        self.calendarID = nil
        visits.resetSyncState()
    }

    func forgetCalendar() {
        calendarID = nil
    }
}
