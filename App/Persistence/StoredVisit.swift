import Foundation
import SharedModels
import SwiftData

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

    init(id: String = UUID().uuidString, arrival: Date, departure: Date?, latitude: Double, longitude: Double) {
        self.id = id
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        isNamedPlace = false
        isResolved = false
    }

    var domain: PlaceVisit {
        PlaceVisit(id: id, arrival: arrival, departure: departure, latitude: latitude, longitude: longitude,
                   placeName: placeName, placeCategory: placeCategory, isNamedPlace: isNamedPlace)
    }
}
