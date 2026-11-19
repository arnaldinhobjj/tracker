import AIKit
import SwiftUI

/// Opt-in AI suggestions (DayLedger Pro), run on the DayLedger backend.
struct AISettingsSection: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    let assistant: AssistantViewModel

    @State private var previewJSON: String?

    private var provider: AIProvider? { environment.aiProviders.first }
    /// AI suggestions are a Pro feature. The toggle can still be turned off without Pro.
    private var isPro: Bool { environment.proAccess == .available }

    var body: some View {
        Section {
            Toggle("AI suggestions", isOn: $settings.aiAssistantEnabled)
                .accessibilityIdentifier("aiToggle")
                .disabled(!isPro && !settings.aiAssistantEnabled)
            if !isPro {
                Button("AI suggestions need DayLedger Pro") { environment.requestPro() }
                    .disabled(environment.proAccess == .unavailable)
            }

            if settings.aiAssistantEnabled, let provider {
                LabeledContent("Provider", value: provider.displayName)
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
            Text("AI suggestions")
        } footer: {
            Text("Optional, part of DayLedger Pro. When you tap \"Suggest\", an anonymised summary goes through DayLedger's server to Anthropic's Claude: never bank credentials, account details, coordinates, addresses, individual transactions or event titles. DayLedger stores neither the summary nor the answer, only a daily request count. Suggestions are added to your calendar only after you approve them.")
        }
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
}
