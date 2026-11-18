import BackgroundTasks
import Foundation

/// Opportunistic background refresh. iOS decides when (and whether) this runs, typically
/// a few times a day for apps the user opens often. It is not real-time.
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist (project.yml).
    static let taskIdentifier = "app.dayledger.refresh"

    static func schedule(after interval: TimeInterval = 30 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails on the simulator and when Background App Refresh is off; nothing else to do.
        }
    }
}
