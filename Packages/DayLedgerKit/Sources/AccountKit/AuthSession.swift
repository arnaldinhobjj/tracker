import Foundation

/// The signed-in DayLedger account.
public struct AuthUser: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let email: String?

    public init(id: UUID, email: String?) {
        self.id = id
        self.email = email
    }
}

/// A Supabase Auth session. Persisted only in the Keychain (`SecureStoreKey.supabaseSession`).
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: UUID
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }

    public var user: AuthUser { AuthUser(id: userID, email: email) }

    /// True if the access token has expired or will within `leeway` seconds.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.addingTimeInterval(-leeway) <= now
    }
}

/// What `signUp` produced.
public enum SignUpResult: Equatable, Sendable {
    /// Email confirmation is off: the account is ready and signed in.
    case signedIn(AuthSession)
    /// Email confirmation is on: the user must open the link we emailed them.
    case confirmationRequired(email: String)
}

/// The outcome of opening a `dayledger://auth-callback` link.
public struct AuthCallbackResult: Equatable, Sendable {
    public let session: AuthSession
    /// The link came from "Forgot password": ask for a new password next.
    public let isPasswordRecovery: Bool

    public init(session: AuthSession, isPasswordRecovery: Bool) {
        self.session = session
        self.isPasswordRecovery = isPasswordRecovery
    }
}

/// A Google sign-in to open in `ASWebAuthenticationSession`. Keep `codeVerifier` until the callback.
public struct OAuthAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let callbackScheme: String
    public let codeVerifier: String

    public init(url: URL, callbackScheme: String, codeVerifier: String) {
        self.url = url
        self.callbackScheme = callbackScheme
        self.codeVerifier = codeVerifier
    }
}

// MARK: - GoTrue wire types

struct GoTrueUserDTO: Decodable {
    let id: UUID
    let email: String?
}

/// A GoTrue token/sign-up response. With email confirmation on, `/signup` returns the bare user
/// object instead (top-level `id`/`email`, no tokens).
struct GoTrueSessionDTO: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let expiresAt: Double?
    let user: GoTrueUserDTO?
    let id: UUID?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
        case id
        case email
    }

    /// `expires_in` is preferred over `expires_at` so a wrong device clock doesn't matter.
    func session(now: Date, previousRefreshToken: String? = nil, fallbackUser: AuthUser? = nil) -> AuthSession? {
        guard let accessToken, !accessToken.isEmpty,
              let refresh = refreshToken ?? previousRefreshToken else { return nil }
        let userID: UUID
        let email: String?
        if let user {
            userID = user.id
            email = user.email
        } else if let fallbackUser {
            userID = fallbackUser.id
            email = fallbackUser.email
        } else {
            return nil
        }
        let expiry: Date
        if let expiresIn {
            expiry = now.addingTimeInterval(expiresIn)
        } else if let expiresAt {
            expiry = Date(timeIntervalSince1970: expiresAt)
        } else {
            expiry = now.addingTimeInterval(3600)
        }
        return AuthSession(accessToken: accessToken, refreshToken: refresh, expiresAt: expiry, userID: userID, email: email)
    }
}

/// The verifier for an email link (sign-up confirmation or password reset) we are waiting for.
struct PendingEmailLink: Codable, Equatable {
    enum Purpose: String, Codable {
        case signUp
        case recovery
    }

    let codeVerifier: String
    let purpose: Purpose
    let createdAt: Date
}
