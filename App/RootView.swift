import AuthenticationServices
import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case today, places, suggestions, settings }

    let environment: AppEnvironment
    @State private var today: TodayViewModel
    @State private var bankModel: BankConnectionViewModel
    @State private var assistant: AssistantViewModel
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
        _assistant = State(initialValue: AssistantViewModel(environment: environment))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(model: today, connectBank: connectBank)
                .tabItem { Label("Today", systemImage: "sterlingsign.circle") }
                .tag(Tab.today)

            PlacesView(environment: environment)
                .tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
                .tag(Tab.places)

            AssistantView(environment: environment, model: assistant)
                .tabItem { Label("Suggest", systemImage: "sparkles") }
                .tag(Tab.suggestions)

            SettingsView(environment: environment, bankModel: bankModel, assistant: assistant, onDataErased: dataErased)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await today.onAppear() }
            }
        }
        .onChange(of: environment.cloudSync.lastSync) { _, _ in
            // Pulled changes from another device.
            today.reloadFromCache()
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
