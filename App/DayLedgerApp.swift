import SwiftUI

@main
@MainActor
struct DayLedgerApp: App {
    @State private var environment = AppEnvironment.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
        .modelContainer(environment.modelContainer)
    }
}
