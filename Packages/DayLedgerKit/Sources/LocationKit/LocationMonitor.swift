import CoreLocation
import Foundation
import Observation

public enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .denied
        }
    }

    public var canMonitor: Bool { self == .whenInUse || self == .always }
}

/// A visit as reported by iOS. Unknown arrival/departure are `nil`
/// (iOS uses `distantPast` / `distantFuture` for those).
public struct VisitEvent: Equatable, Sendable {
    public var arrival: Date?
    public var departure: Date?
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double

    public init(arrival: Date?, departure: Date?, latitude: Double, longitude: Double, horizontalAccuracy: Double) {
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    init(_ visit: CLVisit) {
        arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        latitude = visit.coordinate.latitude
        longitude = visit.coordinate.longitude
        horizontalAccuracy = visit.horizontalAccuracy
    }
}

/// Battery-friendly location logging: visit monitoring plus significant-location-change
/// monitoring. No continuous GPS. Both services relaunch the app in the background when
/// "Always" is granted, so the monitor must be created early at launch.
@MainActor
@Observable
public final class LocationMonitor: NSObject {
    public private(set) var authorization: LocationAuthorization
    public private(set) var isMonitoring = false
    /// Called on the main actor for each visit iOS reports.
    @ObservationIgnored public var onVisit: (@MainActor (VisitEvent) -> Void)?

    @ObservationIgnored private let manager: CLLocationManager

    public override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorization = LocationAuthorization(manager.authorizationStatus)
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Step 1: ask for "While Using the App".
    public func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Step 2, only after explaining why: ask to upgrade to "Always".
    /// iOS shows this prompt at most once; after that the user must change it in Settings.
    public func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    public func startMonitoring() {
        guard authorization.canMonitor else { return }
        manager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        isMonitoring = true
    }

    public func stopMonitoring() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        isMonitoring = false
    }
}

extension LocationMonitor: CLLocationManagerDelegate {
    nonisolated public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let event = VisitEvent(visit)
        Task { @MainActor in
            self.onVisit?(event)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = LocationAuthorization(status)
            if !self.authorization.canMonitor, self.isMonitoring {
                self.stopMonitoring()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Significant-change updates only exist to wake the app so pending visits and
        // calendar writes get processed; the coordinates themselves aren't stored.
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (e.g. kCLErrorLocationUnknown); iOS keeps trying.
    }
}
