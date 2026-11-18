import Foundation

/// A stay at one place, as detected by iOS visit monitoring.
public struct PlaceVisit: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var arrival: Date
    /// `nil` while the visit is still in progress.
    public var departure: Date?
    public var latitude: Double
    public var longitude: Double
    /// e.g. "Costa Coffee"; an address when no point of interest was found; `nil` before resolving.
    public var placeName: String?
    /// MapKit point-of-interest category raw value, e.g. "MKPOICategoryCafe".
    public var placeCategory: String?
    /// True when the name came from a point of interest rather than a street address.
    public var isNamedPlace: Bool

    public init(id: String, arrival: Date, departure: Date?, latitude: Double, longitude: Double,
                placeName: String? = nil, placeCategory: String? = nil, isNamedPlace: Bool = false) {
        self.id = id
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.placeCategory = placeCategory
        self.isNamedPlace = isNamedPlace
    }

    public var duration: TimeInterval? {
        departure.map { $0.timeIntervalSince(arrival) }
    }

    /// Friendly category name, e.g. "Cafe" from "MKPOICategoryCafe".
    public var categoryName: String? {
        guard let raw = placeCategory, !raw.isEmpty else { return nil }
        let trimmed = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        // "PublicTransport" -> "Public Transport"
        return trimmed.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

public enum Geo {
    /// Great-circle distance in metres.
    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

public enum VisitMerging {
    /// iOS often reports a visit twice: once on arrival (no departure) and again when you leave.
    /// Two reports are the same visit if they start within `arrivalTolerance` and are close together.
    public static func isSameVisit(arrivalA: Date, latA: Double, lonA: Double,
                                   arrivalB: Date, latB: Double, lonB: Double,
                                   arrivalTolerance: TimeInterval = 5 * 60, distanceTolerance: Double = 150) -> Bool {
        abs(arrivalA.timeIntervalSince(arrivalB)) <= arrivalTolerance
            && Geo.distance(lat1: latA, lon1: lonA, lat2: latB, lon2: lonB) <= distanceTolerance
    }
}
