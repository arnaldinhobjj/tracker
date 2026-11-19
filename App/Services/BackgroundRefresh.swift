import BackgroundTasks
import Foundation

/// Opportunistic background work. iOS decides when (and whether) this runs, typically a few times
/// a day for apps the user opens often. It is not real-time.
///
/// - App refresh (`taskIdentifier`, ~30 s): handled by SwiftUI's `.backgroundTask` in
///   `DayLedgerApp`; runs the full sync pipeline.
/// - Processing (`processingIdentifier`, minutes, needs network, usually overnight on power): for
///   work that may not fit in a refresh, such as a first cloud sync or a calendar backfill.
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist (project.yml).
    static let taskIdentifier = "app.dayledger.refresh"
    static let processingIdentifier = "app.dayledger.processing"

    /// Runs the processing task's work. Set by `AppRoot` (the environment can be replaced).
    @MainActor static var processingHandler: (@MainActor () async -> Void)?

    static func schedule(after interval: TimeInterval = 30 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        submit(request)
    }

    static func scheduleProcessing(after interval: TimeInterval = 4 * 3600) {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        submit(request)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails on the simulator and when Background App Refresh is off; nothing else to do.
            Log.background.debug("Couldn't schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Call once, before the app finishes launching.
    static func registerProcessing() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            let completion = TaskCompletion(task)
            task.expirationHandler = {
                Log.background.info("Processing task expired")
                completion.finish(success: false)
            }
            Task { @MainActor in
                Log.background.info("Processing task started")
                await processingHandler?()
                completion.finish(success: true)
            }
        }
        if !registered {
            Log.background.error("Couldn't register the processing task; is it in BGTaskSchedulerPermittedIdentifiers?")
        }
    }
}

/// Completes a BGTask exactly once (the work finishing and the expiry can race).
private final class TaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        let shouldComplete = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if shouldComplete { task.setTaskCompleted(success: success) }
    }
}
