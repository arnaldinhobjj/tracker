import Foundation

/// Values injected from `Config/*.xcconfig` into Info.plist at build time.
/// No secrets are hard-coded in source; see README "Configuration".
struct AppConfiguration {
    var trueLayerClientID: String
    /// Sandbox / development only. Production should exchange tokens on a backend.
    var trueLayerClientSecret: String
    var trueLayerEnvironment: String
    var googleClientID: String
    var appGroupID: String
    /// DayLedger account backend. Empty until set in Config/Local.xcconfig.
    var supabaseURL: String = ""
    var supabaseAnonKey: String = ""
    /// Shown on the paywall. Nil when not configured.
    var termsURL: URL?
    var privacyURL: URL?

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return nil
        }
        return url
    }

    static func fromBundle(_ bundle: Bundle = .main) -> AppConfiguration {
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unset build setting can leave the literal "$(NAME)" behind.
            return trimmed.hasPrefix("$(") ? "" : trimmed
        }
        return AppConfiguration(
            trueLayerClientID: value("DLTrueLayerClientID"),
            trueLayerClientSecret: value("DLTrueLayerClientSecret"),
            trueLayerEnvironment: value("DLTrueLayerEnvironment"),
            googleClientID: value("DLGoogleClientID"),
            appGroupID: value("DLAppGroupID"),
            supabaseURL: value("DLSupabaseURL"),
            supabaseAnonKey: value("DLSupabaseAnonKey"),
            termsURL: webURL(value("DLTermsURL")),
            privacyURL: webURL(value("DLPrivacyURL"))
        )
    }
}
