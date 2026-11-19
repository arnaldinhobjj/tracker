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
                existing.touch()
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
        visit.touch()
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
        // Calendar bookkeeping is local to this device and never synced: not a cloud change.
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

    // MARK: Cloud sync

    func allVisits() -> [StoredVisit] {
        (try? context.fetch(FetchDescriptor<StoredVisit>())) ?? []
    }

    /// Visits changed since they were last pushed or pulled.
    func cloudDirty() -> [StoredVisit] {
        (try? context.fetch(FetchDescriptor<StoredVisit>(predicate: #Predicate { $0.needsCloudPush == true }))) ?? []
    }

    /// The visits were pushed as they were at `date`; one edited during the upload stays marked.
    func markCloudSynced(ids: Set<String>, at date: Date) {
        let list = Array(ids)
        for visit in (try? context.fetch(FetchDescriptor<StoredVisit>(predicate: #Predicate { list.contains($0.id) }))) ?? [] {
            visit.cloudSyncedAt = date
            visit.needsCloudPush = CloudMerge.isDirty(updatedAt: visit.updatedAt, syncedAt: date)
        }
        try? context.save()
    }

    /// Applies pulled, decrypted rows (last write wins by server time). Returns true if anything changed.
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
            // Still encrypted (sealed with a key this device lacks): nothing to apply.
            guard let content = row.content else { continue }
            let visit = local ?? StoredVisit(id: row.id, arrival: content.arrival, departure: content.departure,
                                             latitude: content.latitude, longitude: content.longitude)
            if local == nil {
                context.insert(visit)
                byID[row.id] = visit
            }
            visit.arrival = content.arrival
            visit.departure = content.departure
            visit.latitude = content.latitude
            visit.longitude = content.longitude
            visit.placeName = content.placeName
            visit.placeCategory = content.placeCategory
            visit.isNamedPlace = content.isNamedPlace
            visit.isResolved = content.isResolved
            // Calendar acknowledgements stay local: they describe this device's Google calendar,
            // which may be a different calendar (or account) from the device that pushed the row.
            visit.updatedAt = now
            // Plaintext rows from older versions stay "not synced": with visit sync on they are
            // uploaded again encrypted, replacing the plaintext copy.
            visit.cloudSyncedAt = row.isLegacyPlaintext ? nil : now
            visit.needsCloudPush = row.isLegacyPlaintext
            changed = true
        }
        try context.save()
        return changed
    }

    /// Marks every visit as not synced (another account signed in on this device).
    func resetCloudSyncState() {
        for visit in allVisits() {
            visit.cloudSyncedAt = nil
            visit.needsCloudPush = true
        }
        try? context.save()
    }
}
