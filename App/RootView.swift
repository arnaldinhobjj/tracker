import AuthenticationServices
import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case today, settings }

    let environment: AppEnvironment
    @State private var today: TodayViewModel
    @State private var bankModel: BankConnectionViewModel
    @State private var selectedTab = Tab.today
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(environment: AppEnvironment) {
        self.environment = environment
        _today = State(initialValue: TodayViewModel(
            repository: environment.transactionRepository,
            bank: environment.bankService,
            sync: environment.transactionSync
        ))
        _bankModel = State(initialValue: BankConnectionViewModel(bank: environment.bankService, sync: environment.transactionSync))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(model: today, connectBank: connectBank)
                .tabItem { Label("Today", systemImage: "sterlingsign.circle") }
                .tag(Tab.today)

            SettingsView(environment: environment, bankModel: bankModel, onDataErased: dataErased)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await today.onAppear() }
            }
        }
        .onChange(of: bankModel.connections) { _, _ in
            today.reloadFromCache()
            environment.widgetPublisher.publish()
        }
        .alert(item: $bankModel.error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }

    private func connectBank() {
        Task {
            await bankModel.connect(using: webAuthenticationSession)
            today.reloadFromCache()
        }
    }

    private func dataErased() {
        bankModel.reload()
        today.reloadFromCache()
        selectedTab = .today
    }
}
