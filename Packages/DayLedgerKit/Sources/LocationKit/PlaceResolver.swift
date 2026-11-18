import CoreLocation
import Foundation
import MapKit

public struct ResolvedPlace: Equatable, Sendable {
    public var name: String
    public var category: String?
    /// True for a business or landmark ("Costa Coffee"), false for an address fallback.
    public var isPointOfInterest: Bool

    public init(name: String, category: String?, isPointOfInterest: Bool) {
        self.name = name
        self.category = category
        self.isPointOfInterest = isPointOfInterest
    }
}

public protocol PlaceResolving: Sendable {
    func resolve(latitude: Double, longitude: Double) async -> ResolvedPlace?
}

/// Finds the nearest point of interest with MapKit, falling back to a reverse-geocoded address.
/// Visit coordinates are approximate, so this is a best guess, not a certainty.
public struct MapKitPlaceResolver: PlaceResolving {
    public var searchRadius: CLLocationDistance

    public init(searchRadius: CLLocationDistance = 75) {
        self.searchRadius = searchRadius
    }

    public func resolve(latitude: Double, longitude: Double) async -> ResolvedPlace? {
        let location = CLLocation(latitude: latitude, longitude: longitude)

        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: searchRadius)
        if let response = try? await MKLocalSearch(request: request).start() {
            let nearest = response.mapItems
                .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                    guard let itemLocation = item.placemark.location, item.name != nil else { return nil }
                    return (item, itemLocation.distance(from: location))
                }
                .min { $0.1 < $1.1 }
            if let item = nearest?.0, let name = item.name {
                return ResolvedPlace(name: name, category: item.pointOfInterestCategory?.rawValue, isPointOfInterest: true)
            }
        }

        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let name = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let fallback = name.isEmpty ? (placemark.name ?? placemark.locality) : name
            if let fallback, !fallback.isEmpty {
                return ResolvedPlace(name: fallback, category: nil, isPointOfInterest: false)
            }
        }
        return nil
    }
}
