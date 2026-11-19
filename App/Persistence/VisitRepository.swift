import AccountKit
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
            if let departure = event.departure {
                existing.departure = departure
                existing.updatedAt = Date()
            }
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
        visit.updatedAt = Date()
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
        visit.updatedAt = Date()
        try? context.save()
    }

    /// Forget sync state, e.g. after the DayLedger calendar was deleted, so everything is rewritten.
    func resetSyncState() {
        for visit in (try? context.fetch(FetchDescriptor<StoredVisit>())) ?? [] {
            visit.calendarEventID = nil
            visit.calendarContentHash = nil
            visit.calendarSyncedAt = nil
            visit.updatedAt = Date()
        }
        try? context.save()
    }

    func deleteAll() throws {
        try context.delete(model: StoredVisit.self)
        try context.save()
    }

    // MARK: Cloud sync

    func allVisits() -> [StoredVisit] {
        (try? context.fetch(FetchDescriptor<StoredVisit>())) ?? []
    }

    /// Visits changed since they were last pushed or pulled.
    func cloudDirty() -> [StoredVisit] {
        allVisits().filter { CloudMerge.isDirty(updatedAt: $0.updatedAt, syncedAt: $0.cloudSyncedAt) }
    }

    func markCloudSynced(ids: Set<String>, at date: Date) {
        for visit in allVisits() where ids.contains(visit.id) {
            visit.cloudSyncedAt = date
        }
        try? context.save()
    }

    /// Applies pulled rows (last write wins by server time). Returns true if anything changed.
    @discardableResult
    func applyRemote(_ rows: [VisitSyncRow], now: Date = Date()) throws -> Bool {
        guard !rows.isEmpty else { return false }
        let ids = rows.map(\.id)
        let existing = try context.fetch(FetchDescriptor<StoredVisit>(predicate: #Predicate { ids.contains($0.id) }))
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for row in rows {
            let local = byID[row.id]
            let remoteUpdated = row.updatedAt.flatMap(ISO8601.date(from:))
            guard CloudMerge.shouldApplyRemote(remoteUpdatedAt: remoteUpdated, localUpdatedAt: local?.updatedAt,
                                               localSyncedAt: local?.cloudSyncedAt, localExists: local != nil) else { continue }
            if row.deletedAt != nil {
                if let local {
                    context.delete(local)
                    byID[row.id] = nil
                    changed = true
                }
                continue
            }
            let visit = local ?? StoredVisit(id: row.id, arrival: row.arrival, departure: row.departure, latitude: row.latitude, longitude: row.longitude)
            if local == nil {
                context.insert(visit)
                byID[row.id] = visit
            }
            visit.arrival = row.arrival
            visit.departure = row.departure
            visit.latitude = row.latitude
            visit.longitude = row.longitude
            visit.placeName = row.placeName
            visit.placeCategory = row.placeCategory
            visit.isNamedPlace = row.isNamedPlace
            visit.isResolved = row.isResolved
            // Calendar acknowledgements stay local: they describe this device's Google calendar,
            // which may be a different calendar (or account) from the device that pushed the row.
            visit.updatedAt = now
            visit.cloudSyncedAt = now
            changed = true
        }
        try context.save()
        return changed
    }

    /// Marks every visit as not synced (another account signed in on this device).
    func resetCloudSyncState() {
        for visit in allVisits() { visit.cloudSyncedAt = nil }
        try? context.save()
    }
}
