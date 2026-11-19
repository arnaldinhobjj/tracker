import AuthenticationServices
import CalendarKit
import SwiftUI
import UIKit

/// Settings → Calendar: where visits go (Apple Calendar by default, or Google Calendar), the
/// permission or sign-in each needs, and turning calendar writing on.
struct CalendarSettingsSection: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    @Bindable var sync: CalendarSyncService
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSigningIn = false
    @State private var isRequestingAccess = false
    @State private var authorized = false
    @State private var appleAccess = EventAccess.notDetermined

    var body: some View {
        Section {
            Picker("Calendar", selection: Binding(get: { settings.calendarDestination }, set: { kind in
                sync.switchDestination(to: kind)
                refresh()
            })) {
                ForEach(CalendarDestinationKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier("calendarDestination")

            switch settings.calendarDestination {
            case .apple: appleAccessRows
            case .google: googleAccountRows
            }

            if authorized {
                writingRows
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app, where calendar access may have changed.
            if phase == .active { refresh() }
        }
    }

    private var footer: String {
        switch settings.calendarDestination {
        case .apple:
            return "DayLedger writes only to its own \"DayLedger\" calendar on this iPhone (in iCloud if your calendars sync there). iOS asks for full calendar access so DayLedger can update its events instead of duplicating them; from your other calendars it reads only busy/free times, never titles or details."
        case .google:
            return "DayLedger writes only to its own \"DayLedger\" calendar and can see only free/busy times in your other calendars."
        }
    }

    // MARK: Apple Calendar

    @ViewBuilder
    private var appleAccessRows: some View {
        switch appleAccess {
        case .granted:
            LabeledContent("Calendar access", value: "Allowed")
        case .notDetermined:
            Button {
                requestAppleAccess()
            } label: {
                if isRequestingAccess {
                    ProgressView()
                } else {
                    // Plain text: the audit reported the icon-and-title label as not fully
                    // scaling with Dynamic Type.
                    Text("Allow calendar access")
                }
            }
            .disabled(isRequestingAccess)
            .accessibilityIdentifier("allowCalendarAccess")
        case .writeOnly, .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label(appleAccess == .writeOnly ? "Full access needed" : "Calendar access is off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Turn on Full Access for DayLedger in Settings → Privacy & Security → Calendars.")
                    .font(.footnote)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func requestAppleAccess() {
        isRequestingAccess = true
        Task {
            defer { isRequestingAccess = false; refresh() }
            do {
                try await environment.appleCalendar.requestAccess()
            } catch {
                sync.error = UserFacingError(error)
            }
        }
    }

    // MARK: Google Calendar

    @ViewBuilder
    private var googleAccountRows: some View {
        if !sync.isConfigured {
            Label("Add your Google iOS client ID to Config/Local.xcconfig to use Google Calendar.", systemImage: "wrench.and.screwdriver")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if authorized {
            LabeledContent("Google account", value: "Signed in")
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

    // MARK: Writing

    @ViewBuilder
    private var writingRows: some View {
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
    }

    private func refresh() {
        appleAccess = environment.appleCalendar.access
        authorized = sync.isAuthorized
    }
}
