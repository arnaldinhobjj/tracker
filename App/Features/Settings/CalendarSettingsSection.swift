import AuthenticationServices
import CalendarKit
import SwiftUI

struct CalendarSettingsSection: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    @Bindable var sync: CalendarSyncService
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false
    @State private var signedIn = false

    var body: some View {
        Section {
            if !sync.isConfigured {
                Label("Add your Google iOS client ID to Config/Local.xcconfig to enable calendar sync.", systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if signedIn {
                LabeledContent("Google account", value: "Signed in")
                Toggle("Write visits to calendar", isOn: $settings.calendarWritingEnabled)
                    .onChange(of: settings.calendarWritingEnabled) { _, enabled in
                        if enabled { Task { await sync.sync() } }
                    }
                if settings.calendarWritingEnabled {
                    Button {
                        Task { await sync.sync() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            Spacer()
                            if sync.isSyncing {
                                ProgressView()
                            } else if let result = sync.lastResult {
                                Text(result).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(sync.isSyncing)
                }
                if let error = sync.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error.message).font(.footnote)
                        if error.action == .signInGoogle {
                            Button("Sign in again") { signIn() }
                        }
                    }
                }
                Button("Sign out of Google", role: .destructive) {
                    Task {
                        await environment.googleAuth.signOut()
                        settings.calendarWritingEnabled = false
                        refresh()
                    }
                }
            } else {
                Button {
                    signIn()
                } label: {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(isSigningIn)
            }
        } header: {
            Text("Google Calendar")
        } footer: {
            Text("DayLedger writes only to its own \"DayLedger\" calendar and can see only free/busy times in your other calendars.")
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        signedIn = sync.isSignedIn
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        Task {
            defer { isSigningIn = false; refresh() }
            do {
                let request = try environment.googleAuth.makeAuthorizationRequest()
                let callback = try await webAuthenticationSession.authenticate(
                    using: request.url, callbackURLScheme: request.callbackScheme, preferredBrowserSession: .ephemeral)
                try await environment.googleAuth.completeAuthorization(callbackURL: callback, request: request)
                sync.error = nil
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Cancelled.
            } catch {
                sync.error = UserFacingError(error)
            }
        }
    }
}
