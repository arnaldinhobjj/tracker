import Foundation

/// OAuth 2.0 tokens. Persisted only in the Keychain (see `SecureStore`).
public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True if the access token has expired or will within `leeway` seconds.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.addingTimeInterval(-leeway) <= now
    }
}

/// The standard token endpoint response (RFC 6749 §5.1).
public struct OAuthTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let expiresIn: Int?
    public let refreshToken: String?
    public let tokenType: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
    }

    /// Converts to stored tokens. Keeps `previousRefreshToken` if the server didn't rotate it.
    public func tokens(now: Date = Date(), previousRefreshToken: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previousRefreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn ?? 3600)),
            scope: scope
        )
    }
}

/// The standard token endpoint error body (RFC 6749 §5.2), e.g. `{"error":"invalid_grant"}`.
public struct OAuthErrorResponse: Decodable, Sendable {
    public let error: String
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    public static func parse(_ body: String?) -> OAuthErrorResponse? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
    }
}

/// Helpers for reading OAuth redirect callbacks.
public enum OAuthCallback {
    /// Returns the value of a query item in a callback URL.
    public static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    /// A random URL-safe string for `state` and PKCE verifiers.
    public static func randomURLSafeString(length: Int = 43) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
