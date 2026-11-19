import Observation
import SwiftData
import SwiftUI

@main
@MainActor
struct DayLedgerApp: App {
    @State private var root = AppRoot()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask handlers must be registered before launch finishes. (The app refresh
        // task is handled by SwiftUI's `.backgroundTask` below.)
        BackgroundRefresh.registerProcessing()
        MetricsReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            AppGateView(environment: root.environment)
                // A new environment (developer sign-in or sign-out) starts every screen afresh.
                .id(ObjectIdentifier(root.environment))
                .onOpenURL { url in
                    // Only `dayledger://auth-callback` is handled here. Bank and Google sign-ins
                    // come back through ASWebAuthenticationSession, not through this handler.
                    _ = root.environment.account.handleOpenURL(url)
                }
        }
        .modelContainer(root.environment.modelContainer)
        .onChange(of: scenePhase) { _, phase in
            let environment = root.environment
            switch phase {
            case .active:
                // Every launch, not only when going to the background, so refreshes keep coming
                // even if the app is never backgrounded normally (e.g. it's killed).
                BackgroundRefresh.schedule()
                // Midnight rollover while the app was closed: update the widget straight away.
                environment.widgetPublisher.publish()
                Task { await environment.appDidBecomeActive() }
            case .background:
                BackgroundRefresh.schedule()
                BackgroundRefresh.scheduleProcessing()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await root.environment.performBackgroundRefresh()
        }
    }
}

/// Owns the app's `AppEnvironment`. Debug builds replace it when the developer account signs in
/// or out, because that account runs on mock services.
@MainActor
@Observable
final class AppRoot {
    private(set) var environment: AppEnvironment

    init() {
        environment = AppEnvironment.makeDefault()
        wire()
    }

    private func wire() {
        environment.account.onDeveloperSessionChanged = { [weak self] in
            self?.rebuild()
        }
        BackgroundRefresh.processingHandler = { [weak self] in
            await self?.environment.performBackgroundProcessing()
        }
        // Don't submit the app refresh request here: SwiftUI registers the `.backgroundTask`
        // handler only once the scene exists, and submitting before that is an assertion failure.
        // It is scheduled when the app becomes active (every launch) and goes to the background.
    }

    private func rebuild() {
        environment.shutDown()
        environment = AppEnvironment.makeDefault()
        wire()
    }
}
