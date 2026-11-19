#if DEBUG
import AccountKit
import Foundation

/// Debug-only developer login ("admin" / "123") so the app can be explored without a backend.
///
/// Compiled out of Release builds entirely: an App Store build has no backdoor. The password is
/// only ever compared here; it is never stored. Signing in with it uses a local account on this
/// device with mock data, no Supabase calls and no cloud sync.
enum DeveloperLogin {
    static let username = "admin"
    static let userID = UUID(uuidString: "00000000-0000-4000-8000-0000000AD317")!
    static let email = "admin@dayledger.local"
    static let user = AuthUser(id: userID, email: email)

    /// UserDefaults key for "the developer account is signed in" (not the password).
    static let sessionKey = "debug.developerSession"

    /// True only for exactly "admin" / "123" (the username ignores case and surrounding spaces,
    /// as the email field does).
    static func matches(email: String, password: String) -> Bool {
        isDeveloperUsername(email) && password == "123"
    }

    static func isDeveloperUsername(_ email: String) -> Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == username
    }

    static func isSignedIn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: sessionKey)
    }

    static func setSignedIn(_ signedIn: Bool, defaults: UserDefaults = .standard) {
        if signedIn {
            defaults.set(true, forKey: sessionKey)
        } else {
            defaults.removeObject(forKey: sessionKey)
        }
    }
}
#endif
