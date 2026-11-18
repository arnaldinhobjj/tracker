import SwiftData
import SwiftUI

@main
@MainActor
struct DayLedgerApp: App {
    @State private var environment = AppEnvironment.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
        .modelContainer(environment.modelContainer)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Also handles midnight rollover while the app was closed.
                environment.widgetPublisher.publish()
            case .background:
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await environment.performBackgroundRefresh()
        }
    }
}
