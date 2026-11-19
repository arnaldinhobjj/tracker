import Foundation
import Networking

public enum CalendarError: Error, Equatable, Sendable {
    /// GOOGLE_IOS_CLIENT_ID is missing from Config/Local.xcconfig.
    case notConfigured
    case notSignedIn
    case authorizationDenied(String)
    case stateMismatch
    /// The refresh token was revoked or expired (Google "Testing" apps: after 7 days). Sign in again.
    case reauthenticationRequired
    /// The granted scopes don't allow this call.
    case insufficientPermissions
    case calendarNotFound
    /// Apple Calendar: full calendar access wasn't granted (or only write-only access was).
    case calendarAccessDenied
    case rateLimited
    case network(NetworkError)
    case api(status: Int, message: String)
}
