import AccountKit
import CalendarKit
import Foundation
import Observation

/// User preferences. Stored in the App Group defaults so extensions can read them.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var locationLoggingEnabled: Bool {
        didSet {
            defaults.set(locationLoggingEnabled, forKey: Keys.location)
            touch()
        }
    }
    var calendarWritingEnabled: Bool {
        didSet {
            defaults.set(calendarWritingEnabled, forKey: Keys.calendar)
            touch()
        }
    }
    /// Only log businesses and landmarks, not street addresses (keeps home and friends' houses out).
    var onlyNamedPlaces: Bool {
        didSet {
            defaults.set(onlyNamedPlaces, forKey: Keys.namedOnly)
            touch()
        }
    }
    /// Shorter stays aren't written to the calendar.
    var minimumVisitMinutes: Int {
        didSet {
            defaults.set(minimumVisitMinutes, forKey: Keys.minimumMinutes)
            touch()
        }
    }

    /// Opt-in AI assistant. Off until the user connects a provider.
    var aiAssistantEnabled: Bool {
        didSet {
            defaults.set(aiAssistantEnabled, forKey: Keys.ai)
            touch()
        }
    }

    /// Which calendar visits and suggestions are written to. Kept on this device only (not synced):
    /// it depends on this iPhone's calendar permission or Google sign-in.
    var calendarDestination: CalendarDestinationKind {
        didSet { defaults.set(calendarDestination.rawValue, forKey: Keys.calendarDestination) }
    }

    /// Upload visits (end-to-end encrypted) to the DayLedger account. Account-wide (synced like
    /// the settings above), and off until the user turns it on: visits are where you've been.
    var visitSyncEnabled: Bool {
        didSet {
            defaults.set(visitSyncEnabled, forKey: Keys.visitSync)
            touch()
        }
    }

    private enum Keys {
        static let visitSync = "settings.visitSync"
        static let calendarDestination = "settings.calendarDestination"
        static let ai = "settings.aiAssistant"
        static let location = "settings.locationLogging"
        static let calendar = "settings.calendarWriting"
        static let namedOnly = "settings.onlyNamedPlaces"
        static let minimumMinutes = "settings.minimumVisitMinutes"
        static let changedAt = "settings.changedAt"
    }

    /// True while settings pulled from the cloud are applied, so they don't count as local edits.
    @ObservationIgnored private var isApplyingRemote = false

    /// When the user last changed a setting on this device (for cloud sync, last write wins).
    var changedAt: Date? {
        defaults.object(forKey: Keys.changedAt) as? Date
    }

    private func touch() {
        guard !isApplyingRemote else { return }
        defaults.set(Date(), forKey: Keys.changedAt)
    }

    /// The settings as stored in `user_settings.settings`.
    var synced: SyncedSettings {
        SyncedSettings(locationLogging: locationLoggingEnabled, calendarWriting: calendarWritingEnabled,
                       onlyNamedPlaces: onlyNamedPlaces, minimumVisitMinutes: minimumVisitMinutes, aiAssistant: aiAssistantEnabled,
                       visitSync: visitSyncEnabled)
    }

    /// Applies settings from another device. Location logging is deliberately not applied: it
    /// needs this iPhone's own permission and consent, so it is only ever turned on here.
    func applyRemote(_ remote: SyncedSettings) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if calendarWritingEnabled != remote.calendarWriting { calendarWritingEnabled = remote.calendarWriting }
        if onlyNamedPlaces != remote.onlyNamedPlaces { onlyNamedPlaces = remote.onlyNamedPlaces }
        if minimumVisitMinutes != remote.minimumVisitMinutes { minimumVisitMinutes = max(1, remote.minimumVisitMinutes) }
        if aiAssistantEnabled != remote.aiAssistant { aiAssistantEnabled = remote.aiAssistant }
        if visitSyncEnabled != remote.visitSync { visitSyncEnabled = remote.visitSync }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Everything that leaves the device or tracks you is off until you turn it on.
        locationLoggingEnabled = defaults.object(forKey: Keys.location) as? Bool ?? false
        let calendarWriting = defaults.object(forKey: Keys.calendar) as? Bool ?? false
        calendarWritingEnabled = calendarWriting
        onlyNamedPlaces = defaults.object(forKey: Keys.namedOnly) as? Bool ?? true
        minimumVisitMinutes = defaults.object(forKey: Keys.minimumMinutes) as? Int ?? 5
        aiAssistantEnabled = defaults.object(forKey: Keys.ai) as? Bool ?? false
        visitSyncEnabled = defaults.object(forKey: Keys.visitSync) as? Bool ?? false
        if let raw = defaults.string(forKey: Keys.calendarDestination), let kind = CalendarDestinationKind(rawValue: raw) {
            calendarDestination = kind
        } else {
            // Apple Calendar for new users. Anyone already writing to Google (before Apple Calendar
            // existed) stays on Google; the choice is saved so it never changes by itself.
            let kind: CalendarDestinationKind = calendarWriting ? .google : .apple
            calendarDestination = kind
            defaults.set(kind.rawValue, forKey: Keys.calendarDestination)
        }
    }

    func resetToDefaults() {
        locationLoggingEnabled = false
        calendarWritingEnabled = false
        onlyNamedPlaces = true
        minimumVisitMinutes = 5
        aiAssistantEnabled = false
        visitSyncEnabled = false
        calendarDestination = .apple
    }
}
