import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @Bindable var bankModel: BankConnectionViewModel
    var onDataErased: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                BankConnectionsSection(model: bankModel)

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
