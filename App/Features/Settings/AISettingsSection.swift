import AIKit
import SecureStore
import SwiftUI

/// Opt-in "Connect AI": the user pastes their own key, stored only in the Keychain.
struct AISettingsSection: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    let assistant: AssistantViewModel

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var previewJSON: String?
    @State private var saveError: String?

    private var provider: AIProvider? { environment.aiProviders.first }
    /// AI suggestions are a Pro feature. The toggle can still be turned off without Pro.
    private var isPro: Bool { environment.proAccess == .available }

    var body: some View {
        Section {
            Toggle("Connect AI", isOn: $settings.aiAssistantEnabled)
                .accessibilityIdentifier("aiToggle")
                .disabled(!isPro && !settings.aiAssistantEnabled)
            if !isPro {
                Button("AI suggestions need DayLedger Pro") { environment.requestPro() }
                    .disabled(environment.proAccess == .unavailable)
            }

            if settings.aiAssistantEnabled, let provider {
                LabeledContent("Provider", value: provider.displayName)
                if hasKey {
                    LabeledContent("API key", value: "Saved in Keychain")
                    Button("Remove API key", role: .destructive) {
                        try? environment.secureStore.remove(SecureStoreKey.aiAPIKey(provider: provider.id))
                        refresh()
                    }
                } else {
                    SecureField("Paste your API key", text: $keyInput)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save key") { save(provider) }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(.red)
                    }
                }
                Button("Preview what would be sent") {
                    Task {
                        let (summary, _) = await assistant.buildSummary()
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                        previewJSON = (try? encoder.encode(summary)).map { String(decoding: $0, as: UTF8.self) }
                    }
                }
            }
        } header: {
            Text("AI assistant")
        } footer: {
            Text("Optional. Uses your own API key and account with the provider; requests are billed to you. DayLedger sends only an anonymised summary when you tap \"Suggest\", never bank credentials, account details, coordinates, addresses or event titles. Suggestions are added to your calendar only after you approve them.")
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: Binding(get: { previewJSON != nil }, set: { if !$0 { previewJSON = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(previewJSON ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Data sent to AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { previewJSON = nil } }
                }
            }
        }
    }

    private func refresh() {
        guard let provider else { return }
        let stored = (try? environment.secureStore.string(for: SecureStoreKey.aiAPIKey(provider: provider.id))) ?? nil
        hasKey = !(stored ?? "").isEmpty
    }

    private func save(_ provider: AIProvider) {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.secureStore.set(key, for: SecureStoreKey.aiAPIKey(provider: provider.id))
            keyInput = ""
            saveError = nil
        } catch {
            saveError = "Couldn't save the key to the Keychain."
        }
        refresh()
    }
}
