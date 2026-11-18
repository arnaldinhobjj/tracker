import Foundation
import LocationKit
import SharedModels
import UIKit

/// Receives visits from iOS, stores them, looks up the place name and kicks off a calendar sync.
@MainActor
final class LocationLoggingService {
    let monitor: LocationMonitor
    private let repository: VisitRepository
    private let resolver: PlaceResolving
    private let settings: AppSettings
    /// Called after a visit is stored or updated (calendar sync hooks in here).
    var onVisitsChanged: (() async -> Void)?

    init(monitor: LocationMonitor, repository: VisitRepository, resolver: PlaceResolving, settings: AppSettings) {
        self.monitor = monitor
        self.repository = repository
        self.resolver = resolver
        self.settings = settings
        monitor.onVisit = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Call at launch: resumes monitoring if the user enabled it, so background relaunches deliver visits.
    func resumeIfEnabled() {
        if settings.locationLoggingEnabled && monitor.authorization.canMonitor {
            monitor.startMonitoring()
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.locationLoggingEnabled = enabled
        if enabled {
            if monitor.authorization == .notDetermined {
                monitor.requestWhenInUse()
            }
            monitor.startMonitoring()
        } else {
            monitor.stopMonitoring()
        }
    }

    /// Re-evaluates after the user answers a permission prompt.
    func authorizationChanged() {
        if settings.locationLoggingEnabled && monitor.authorization.canMonitor && !monitor.isMonitoring {
            monitor.startMonitoring()
        }
    }

    private func handle(_ event: VisitEvent) {
        guard settings.locationLoggingEnabled else { return }
        // Visits usually arrive while the app is in the background; ask for extra time to finish
        // the place lookup and calendar write (iOS grants ~30 seconds).
        let backgroundTask = BackgroundTaskToken(name: "DayLedger visit")
        Task {
            defer { backgroundTask.end() }
            guard let visit = try? repository.record(event) else { return }
            if !visit.isResolved {
                let place = await resolver.resolve(latitude: visit.latitude, longitude: visit.longitude)
                try? repository.applyPlace(place, to: visit)
            }
            await onVisitsChanged?()
        }
    }

    /// Retries place lookups that failed earlier (e.g. offline).
    func resolvePending() async {
        for visit in repository.unresolved() {
            let place = await resolver.resolve(latitude: visit.latitude, longitude: visit.longitude)
            if place != nil {
                try? repository.applyPlace(place, to: visit)
            }
        }
    }
}

/// Wraps `beginBackgroundTask` so the task is ended exactly once (on completion or expiry).
@MainActor
final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
