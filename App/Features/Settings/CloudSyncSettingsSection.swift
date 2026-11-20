import SwiftUI

/// Settings → Cloud sync (signed in): end-to-end encryption status, visit sync (opt-in), and the
/// choice about visits uploaded by older app versions.
struct CloudSyncSettingsSection: View {
    let environment: AppEnvironment

    @State private var confirmingVisitSyncOff = false
    @State private var confirmingStartOver = false
    @State private var showingRecoverySetup = false
    @State private var showingRecoveryEntry = false
    @State private var isWorking = false
    @State private var error: UserFacingError?

    private var cloudSync: CloudSyncService { environment.cloudSync }
    private var settings: AppSettings { environment.settings }

    var body: some View {
        Section {
            switch cloudSync.encryptionStatus {
            case .waitingForKey:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Waiting for your encryption key", systemImage: "key.icloud")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Your synced data is end-to-end encrypted with a key kept in iCloud Keychain, and it hasn't reached this iPhone yet. Turn on iCloud Keychain (Settings → your name → iCloud → Passwords and Keychain) and it will arrive automatically.")
                        .font(.footnote)
                }
                .accessibilityIdentifier("waitingForKey")
                if cloudSync.recoveryStatus == .setUp {
                    Button("Enter recovery key") { showingRecoveryEntry = true }
                        .accessibilityIdentifier("enterRecoveryKey")
                }
                Button("Start over with this iPhone's data", role: .destructive) { confirmingStartOver = true }
                    .disabled(isWorking)
            case .ready:
                Label("End-to-end encrypted", systemImage: "lock.icloud")
                switch cloudSync.recoveryStatus {
                case .setUp:
                    LabeledContent("Recovery key", value: String(localized: "Saved"))
                    Button("Make a new recovery key") { showingRecoverySetup = true }
                        .accessibilityIdentifier("replaceRecoveryKey")
                case .notSetUp:
                    Button("Set up a recovery key") { showingRecoverySetup = true }
                        .accessibilityIdentifier("setUpRecoveryKey")
                case .unknown:
                    EmptyView()
                }
            case .unknown:
                EmptyView()
            }

            Toggle("Sync visits", isOn: Binding(get: { settings.visitSyncEnabled }, set: { setVisitSync($0) }))
                .disabled(isWorking)
                .accessibilityIdentifier("visitSyncToggle")

            if cloudSync.hasLegacyVisitsInCloud && !settings.visitSyncEnabled {
                LegacyVisitsPrompt(environment: environment)
            }
        } header: {
            Text("Cloud sync")
        } footer: {
            Text(footer)
        }
        .confirmationDialog("Stop syncing visits?", isPresented: $confirmingVisitSyncOff, titleVisibility: .visible) {
            Button("Stop and remove from account", role: .destructive) { run { try await cloudSync.disableVisitSyncAndRemoveFromCloud() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Visits already in your account are deleted from it. Visits stored on your devices stay there.")
        }
        .confirmationDialog("Start over with this iPhone's data?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Delete cloud copy and start over", role: .destructive) { run { try await cloudSync.startEncryptionOver() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if your encryption key is lost (for example, iCloud Keychain was turned off on every device). Your account's encrypted transactions and visits are deleted and replaced by this iPhone's data under a new key. Other devices upload their data again once they have the new key.\(environment.proAccess == .available ? "" : "\n\nWithout DayLedger Pro, nothing can be uploaded again until you subscribe.")")
        }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .sheet(isPresented: $showingRecoverySetup) {
            RecoveryKeySetupView(cloudSync: cloudSync, isReplacing: cloudSync.recoveryStatus == .setUp)
        }
        .sheet(isPresented: $showingRecoveryEntry) {
            RecoveryKeyEntryView(cloudSync: cloudSync)
        }
    }

    private var footer: String {
        var text = "Transactions are end-to-end encrypted on this iPhone before they're uploaded: only your devices can read them, not DayLedger. The key is kept in iCloud Keychain; a recovery key lets you restore it without iCloud Keychain. "
        text += settings.visitSyncEnabled
            ? "Visits (places and times) are synced too, encrypted, on all your devices."
            : "Visits stay on your devices unless you turn on visit sync."
        if environment.proAccess != .available {
            text += " Uploading needs DayLedger Pro."
        }
        return text
    }

    private func setVisitSync(_ enabled: Bool) {
        if enabled {
            run { await cloudSync.enableVisitSync() }
        } else {
            confirmingVisitSyncOff = true
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch {
                self.error = UserFacingError(error)
            }
        }
    }
}

/// One-time choice for visits that an older app version uploaded (unencrypted, before visit sync
/// was opt-in): keep them (re-uploaded end-to-end encrypted, visit sync on) or remove them from
/// the account. Nothing happens to them until the user chooses.
struct LegacyVisitsPrompt: View {
    let environment: AppEnvironment

    @State private var isWorking = false
    @State private var error: UserFacingError?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Visits from an earlier version are in your account", systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
            Text("Earlier versions of DayLedger uploaded your visits without end-to-end encryption. Keep them synced (they'll be re-uploaded encrypted), or remove them from your account. They stay on this iPhone either way.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Keep, encrypted") {
                    run { await environment.cloudSync.enableVisitSync() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(environment.proAccess != .available)
                .accessibilityIdentifier("keepLegacyVisits")
                Button("Remove from account", role: .destructive) {
                    run { try await environment.cloudSync.disableVisitSyncAndRemoveFromCloud() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("removeLegacyVisits")
            }
            .disabled(isWorking)
        }
        .padding(.vertical, 4)
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch {
                self.error = UserFacingError(error)
            }
        }
    }
}
