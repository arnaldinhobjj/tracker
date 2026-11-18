import Foundation
import Observation

/// User preferences. Stored in the App Group defaults so extensions can read them.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var locationLoggingEnabled: Bool {
        didSet { defaults.set(locationLoggingEnabled, forKey: Keys.location) }
    }
    var calendarWritingEnabled: Bool {
        didSet { defaults.set(calendarWritingEnabled, forKey: Keys.calendar) }
    }
    /// Only log businesses and landmarks, not street addresses (keeps home and friends' houses out).
    var onlyNamedPlaces: Bool {
        didSet { defaults.set(onlyNamedPlaces, forKey: Keys.namedOnly) }
    }
    /// Shorter stays aren't written to the calendar.
    var minimumVisitMinutes: Int {
        didSet { defaults.set(minimumVisitMinutes, forKey: Keys.minimumMinutes) }
    }

    /// Opt-in AI assistant. Off until the user connects a provider.
    var aiAssistantEnabled: Bool {
        didSet { defaults.set(aiAssistantEnabled, forKey: Keys.ai) }
    }

    private enum Keys {
        static let ai = "settings.aiAssistant"
        static let location = "settings.locationLogging"
        static let calendar = "settings.calendarWriting"
        static let namedOnly = "settings.onlyNamedPlaces"
        static let minimumMinutes = "settings.minimumVisitMinutes"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Everything that leaves the device or tracks you is off until you turn it on.
        locationLoggingEnabled = defaults.object(forKey: Keys.location) as? Bool ?? false
        calendarWritingEnabled = defaults.object(forKey: Keys.calendar) as? Bool ?? false
        onlyNamedPlaces = defaults.object(forKey: Keys.namedOnly) as? Bool ?? true
        minimumVisitMinutes = defaults.object(forKey: Keys.minimumMinutes) as? Int ?? 5
        aiAssistantEnabled = defaults.object(forKey: Keys.ai) as? Bool ?? false
    }

    func resetToDefaults() {
        locationLoggingEnabled = false
        calendarWritingEnabled = false
        onlyNamedPlaces = true
        minimumVisitMinutes = 5
        aiAssistantEnabled = false
    }
}
