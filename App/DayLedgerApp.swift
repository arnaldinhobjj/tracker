import Observation
import SwiftData
import SwiftUI

@main
@MainActor
struct DayLedgerApp: App {
    @State private var root = AppRoot()
    @Environment(\.scenePhase) private var scenePhase

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
                // Also handles midnight rollover while the app was closed.
                environment.widgetPublisher.publish()
                Task {
                    await environment.locationLogging.resolvePending()
                    await environment.calendarSync.sync()
                    if environment.account.isSignedIn {
                        await environment.subscriptions.refreshEntitlement()
                        await environment.cloudSync.sync()
                    }
                }
            case .background:
                BackgroundRefresh.schedule()
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
    }

    private func rebuild() {
        environment.shutDown()
        environment = AppEnvironment.makeDefault()
        wire()
    }
}
