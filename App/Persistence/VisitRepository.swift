import Foundation
import LocationKit
import SharedModels
import SwiftData

@MainActor
final class VisitRepository {
    private let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    /// Stores a visit from iOS, merging it with an earlier report of the same visit
    /// (arrival-only report followed by the full visit). Returns the stored visit.
    @discardableResult
    func record(_ event: VisitEvent) throws -> StoredVisit? {
        // Without an arrival time (monitoring started mid-visit) there is nothing useful to log.
        guard let arrival = event.arrival else { return nil }

        let from = arrival.addingTimeInterval(-3_600)
        let to = arrival.addingTimeInterval(3_600)
        let nearby = try context.fetch(FetchDescriptor<StoredVisit>(predicate: #Predicate { $0.arrival >= from && $0.arrival <= to }))
        if let existing = nearby.first(where: {
            VisitMerging.isSameVisit(arrivalA: $0.arrival, latA: $0.latitude, lonA: $0.longitude,
                                     arrivalB: arrival, latB: event.latitude, lonB: event.longitude)
        }) {
            if let departure = event.departure { existing.departure = departure }
            try context.save()
            return existing
        }

        let visit = StoredVisit(arrival: arrival, departure: event.departure, latitude: event.latitude, longitude: event.longitude)
        context.insert(visit)
        try context.save()
        return visit
    }

    func applyPlace(_ place: ResolvedPlace?, to visit: StoredVisit) throws {
        visit.isResolved = true
        if let place {
            visit.placeName = place.name
            visit.placeCategory = place.category
            visit.isNamedPlace = place.isPointOfInterest
        }
        try context.save()
    }

    func unresolved(limit: Int = 20) -> [StoredVisit] {
        var descriptor = FetchDescriptor<StoredVisit>(predicate: #Predicate { !$0.isResolved },
                                                      sortBy: [SortDescriptor(\.arrival, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func visits(since date: Date) -> [StoredVisit] {
        let descriptor = FetchDescriptor<StoredVisit>(predicate: #Predicate { $0.arrival >= date },
                                                      sortBy: [SortDescriptor(\.arrival, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func markSynced(_ visit: StoredVisit, eventID: String, hash: String, at date: Date = Date()) {
        visit.calendarEventID = eventID
        visit.calendarContentHash = hash
        visit.calendarSyncedAt = date
        try? context.save()
    }

    /// Forget sync state, e.g. after the DayLedger calendar was deleted, so everything is rewritten.
    func resetSyncState() {
        for visit in (try? context.fetch(FetchDescriptor<StoredVisit>())) ?? [] {
            visit.calendarEventID = nil
            visit.calendarContentHash = nil
            visit.calendarSyncedAt = nil
        }
        try? context.save()
    }

    func deleteAll() throws {
        try context.delete(model: StoredVisit.self)
        try context.save()
    }
}
