import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @Bindable var bankModel: BankConnectionViewModel
    let assistant: AssistantViewModel
    var onDataErased: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                AccountSettingsSection(environment: environment, onDataErased: onDataErased)

                BankConnectionsSection(model: bankModel)

                LocationSettingsSection(environment: environment, settings: environment.settings)

                CalendarSettingsSection(environment: environment, settings: environment.settings, sync: environment.calendarSync)

                AISettingsSection(environment: environment, settings: environment.settings, assistant: assistant)

                Section("Privacy") {
                    NavigationLink {
                        PrivacyView(eraser: DataEraser(environment: environment), onErased: onDataErased)
                    } label: {
                        Label("Privacy & your data", systemImage: "hand.raised")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    LabeledContent("Bank environment", value: environment.configuration.trueLayerEnvironment.isEmpty ? "sandbox" : environment.configuration.trueLayerEnvironment)
                }
            }
            .navigationTitle("Settings")
            .onAppear { bankModel.reload() }
        }
    }
}
