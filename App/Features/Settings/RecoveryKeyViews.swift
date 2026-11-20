import AccountKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows a new recovery key once and stores the wrapped sync key only after the user confirms
/// they've kept it, so an earlier recovery key keeps working if they cancel.
struct RecoveryKeySetupView: View {
    let cloudSync: CloudSyncService
    /// The account already has a recovery key: saving this one makes the old one stop working.
    let isReplacing: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey: RecoveryKey?
    @State private var hasKeptIt = false
    @State private var isSaving = false
    @State private var copied = false
    @State private var error: UserFacingError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("If you ever sign in on an iPhone without iCloud Keychain, this key unlocks your synced data. Keep it somewhere safe and private, such as a password manager or on paper. DayLedger can't see it or recover it for you.")
                    if isReplacing {
                        Text("Your previous recovery key stops working when you save this one.")
                            .foregroundStyle(.orange)
                    }
                }

                if let recoveryKey {
                    Section("Your recovery key") {
                        Text(verbatim: recoveryKey.formatted)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel(Text("Recovery key"))
                            .accessibilityValue(Text(verbatim: spokenGroups(recoveryKey.formatted)))
                            .accessibilityIdentifier("recoveryKeyText")
                        Button(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                            copy(recoveryKey.formatted)
                        }
                    }

                    Section {
                        Toggle("I've saved my recovery key somewhere safe", isOn: $hasKeptIt)
                            .accessibilityIdentifier("keptRecoveryKey")
                    }
                }
            }
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The save can't be called back once sent: stay until it finishes, so a
                    // cancelled sheet never replaces the old recovery key behind the user's back.
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!hasKeptIt || recoveryKey == nil)
                            .accessibilityIdentifier("saveRecoveryKey")
                    }
                }
            }
            .alert(item: $error) { error in
                Alert(title: Text(error.title), message: Text(error.message))
            }
            .onAppear {
                if recoveryKey == nil { recoveryKey = cloudSync.newRecoveryKey() }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard let recoveryKey else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await cloudSync.saveRecoveryKey(recoveryKey)
                dismiss()
            } catch {
                // The key on screen is still the one to keep: saving can simply be tried again.
                self.error = UserFacingError(error)
            }
        }
    }

    private func copy(_ text: String) {
        // Not to other devices (Universal Clipboard), and gone from the clipboard after 2 minutes.
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied = true
    }

    /// VoiceOver reads the key group by group, character by character.
    private func spokenGroups(_ formatted: String) -> String {
        formatted.split(separator: "-").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}

/// On a device waiting for the encryption key: restores it from the recovery key the user typed.
struct RecoveryKeyEntryView: View {
    let cloudSync: CloudSyncService

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isRestoring = false
    @State private var error: UserFacingError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the recovery key you saved when you set it up. Spaces, dashes and lower-case letters are fine.")
                }
                Section("Recovery key") {
                    TextField("XXXXX-XXXXX-…", text: $text, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                        .accessibilityIdentifier("recoveryKeyField")
                }
                if let error {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error.title).font(.subheadline.weight(.semibold))
                                Text(error.message).font(.footnote)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Enter recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRestoring)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Button("Restore") { restore() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("restoreWithRecoveryKey")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isRestoring)
    }

    private func restore() {
        isRestoring = true
        error = nil
        Task {
            defer { isRestoring = false }
            do {
                try await cloudSync.restore(withRecoveryKey: text)
                dismiss()
            } catch {
                self.error = UserFacingError(error)
            }
        }
    }
}
