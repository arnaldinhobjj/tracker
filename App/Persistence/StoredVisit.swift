import Foundation
import SharedModels
import SwiftData

/// Changing stored properties needs a new schema version (see SchemaVersions.swift).
@Model
final class StoredVisit {
    @Attribute(.unique) var id: String
    var arrival: Date
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var placeName: String?
    var placeCategory: String?
    var isNamedPlace: Bool
    /// Place lookup has been attempted (successfully or not).
    var isResolved: Bool
    /// Google Calendar event ID and the content hash last written, for skipping unchanged events.
    var calendarEventID: String?
    var calendarContentHash: String?
    var calendarSyncedAt: Date?
    /// Last local change, and when the row last matched the cloud copy. Optional so existing
    /// stores migrate without defaults; a nil `cloudSyncedAt` means "not synced yet".
    var updatedAt: Date?
    var cloudSyncedAt: Date?
    /// True while this visit has local changes the cloud doesn't have yet (SchemaV2).
    var needsCloudPush: Bool = true

    init(id: String = UUID().uuidString, arrival: Date, departure: Date?, latitude: Double, longitude: Double) {
        self.id = id
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        isNamedPlace = false
        isResolved = false
        updatedAt = Date()
    }

    /// Records a change that should reach the cloud.
    func touch(_ date: Date = Date()) {
        updatedAt = date
        needsCloudPush = true
    }

    var domain: PlaceVisit {
        PlaceVisit(id: id, arrival: arrival, departure: departure, latitude: latitude, longitude: longitude,
                   placeName: placeName, placeCategory: placeCategory, isNamedPlace: isNamedPlace)
    }
}
