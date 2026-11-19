import LocationKit
import SwiftUI
import UIKit

struct LocationSettingsSection: View {
    let environment: AppEnvironment
    @Bindable var settings: AppSettings
    @State private var showingAlwaysExplanation = false

    private var monitor: LocationMonitor { environment.locationLogging.monitor }

    var body: some View {
        Section {
            Toggle("Log places I visit", isOn: Binding(
                get: { settings.locationLoggingEnabled },
                set: { environment.locationLogging.setEnabled($0) }
            ))
            .accessibilityIdentifier("locationToggle")

            if settings.locationLoggingEnabled {
                LabeledContent("Permission", value: permissionText)

                switch monitor.authorization {
                case .whenInUse:
                    Button("Allow logging in the background…") { showingAlwaysExplanation = true }
                case .denied, .restricted:
                    Button("Open iOS Settings") { openSettings() }
                default:
                    EmptyView()
                }

                Toggle("Only named places", isOn: $settings.onlyNamedPlaces)
                Stepper("Minimum stay: \(settings.minimumVisitMinutes) min", value: $settings.minimumVisitMinutes, in: 1...60)
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Uses iOS visit detection and significant location changes, not continuous GPS, so battery impact is minimal. \"Only named places\" skips street addresses such as your home.")
        }
        .onChange(of: monitor.authorization) { _, _ in
            environment.locationLogging.authorizationChanged()
        }
        .sheet(isPresented: $showingAlwaysExplanation) {
            AlwaysPermissionExplanation {
                showingAlwaysExplanation = false
                monitor.requestAlways()
            } openSettings: {
                showingAlwaysExplanation = false
                openSettings()
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var permissionText: String {
        switch monitor.authorization {
        case .notDetermined: return "Not asked yet"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .whenInUse: return "While using the app"
        case .always: return "Always"
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct AlwaysPermissionExplanation: View {
    var allow: () -> Void
    var openSettings: () -> Void

    var body: some View {
        // At large text sizes the explanation doesn't fit: let it scroll.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Log visits automatically")
                .font(.title2.bold())
            Text("With \"While Using the App\", iOS only tells DayLedger about places while the app is open, so most visits are missed.")
            Text("\"Always\" lets iOS wake DayLedger briefly when you arrive at or leave a place. DayLedger does not track you continuously: it receives a handful of visit notifications a day. Visits are stored on your iPhone; they're only uploaded to your DayLedger account, end-to-end encrypted, if you turn on visit sync. Only the place name and times are written to your DayLedger calendar.")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: allow) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("If no prompt appears, open Settings → Location → Always", action: openSettings)
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}
