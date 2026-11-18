import CryptoKit
import Foundation
import Networking
import SecureStore

public struct GoogleOAuthConfiguration: Sendable {
    /// An OAuth client of type "iOS" from Google Cloud Console, e.g. "1234-abc.apps.googleusercontent.com".
    public var clientID: String
    public var scopes: [String]

    /// Narrow scopes: manage only calendars this app creates, list calendars (to find the DayLedger
    /// one again after a reinstall) and read free/busy times. No access to event details elsewhere.
    public static let defaultScopes = [
        "https://www.googleapis.com/auth/calendar.app.created",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.freebusy",
    ]

    public init(clientID: String, scopes: [String] = GoogleOAuthConfiguration.defaultScopes) {
        self.clientID = clientID.trimmingCharacters(in: .whitespaces)
        self.scopes = scopes
    }

    public var isConfigured: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com")
    }

    /// iOS clients redirect to the "reversed client ID" scheme, e.g. "com.googleusercontent.apps.1234-abc".
    public var callbackScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }

    public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
}

public struct GoogleAuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let callbackScheme: String
    public let state: String
    let codeVerifier: String
}

/// Lets the calendar client get tokens without knowing how they're stored.
public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
    func refreshAccessToken() async throws -> String
}

/// Google sign-in with OAuth 2.0 authorization code + PKCE. iOS clients have no client secret.
public final class GoogleAuthService: GoogleAccessTokenProviding, @unchecked Sendable {
    public let configuration: GoogleOAuthConfiguration
    private let store: SecureStoring
    private let http: HTTPClient
    private let refresher: TokenRefresher

    public init(configuration: GoogleOAuthConfiguration, store: SecureStoring, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.store = store
        self.http = http
        refresher = TokenRefresher(configuration: configuration, store: store, http: http)
    }

    public var isConfigured: Bool { configuration.isConfigured }

    public var isSignedIn: Bool {
        ((try? store.data(for: SecureStoreKey.googleTokens)) ?? nil) != nil
    }

    public func makeAuthorizationRequest() throws -> GoogleAuthorizationRequest {
        guard isConfigured else { throw CalendarError.notConfigured }
        let verifier = OAuthCallback.randomURLSafeString(length: 64)
        let state = OAuthCallback.randomURLSafeString(length: 32)
        var components = URLComponents(url: GoogleOAuthConfiguration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Ask for consent so Google always returns a refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return GoogleAuthorizationRequest(url: components.url!, callbackScheme: configuration.callbackScheme, state: state, codeVerifier: verifier)
    }

    public func completeAuthorization(callbackURL: URL, request: GoogleAuthorizationRequest) async throws {
        if let error = OAuthCallback.queryValue("error", in: callbackURL) {
            throw CalendarError.authorizationDenied(error)
        }
        guard OAuthCallback.queryValue("state", in: callbackURL) == request.state else {
            throw CalendarError.stateMismatch
        }
        guard let code = OAuthCallback.queryValue("code", in: callbackURL) else {
            throw CalendarError.authorizationDenied("missing_code")
        }
        let tokenRequest = URLRequest.formPost(url: GoogleOAuthConfiguration.tokenEndpoint, parameters: [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": request.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI,
        ])
        do {
            let response = try await http.decode(OAuthTokenResponse.self, from: tokenRequest)
            try store.setValue(response.tokens(), for: SecureStoreKey.googleTokens)
        } catch let error as NetworkError {
            throw TokenRefresher.map(error)
        }
    }

    public func accessToken() async throws -> String {
        try await refresher.accessToken(forceRefresh: false)
    }

    public func refreshAccessToken() async throws -> String {
        try await refresher.accessToken(forceRefresh: true)
    }

    /// Revokes the grant at Google (best effort) and deletes the local tokens.
    public func signOut() async {
        if let tokens = try? store.value(OAuthTokens.self, for: SecureStoreKey.googleTokens) {
            let token = tokens.refreshToken ?? tokens.accessToken
            let request = URLRequest.formPost(url: GoogleOAuthConfiguration.revokeEndpoint, parameters: ["token": token])
            _ = try? await http.send(request)
        }
        try? store.remove(SecureStoreKey.googleTokens)
    }
}

/// Serialises token refreshes so concurrent calendar calls share one.
actor TokenRefresher {
    private let configuration: GoogleOAuthConfiguration
    private let store: SecureStoring
    private let http: HTTPClient
    private var inFlight: Task<OAuthTokens, Error>?

    init(configuration: GoogleOAuthConfiguration, store: SecureStoring, http: HTTPClient) {
        self.configuration = configuration
        self.store = store
        self.http = http
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let tokens = try store.value(OAuthTokens.self, for: SecureStoreKey.googleTokens) else {
            throw CalendarError.notSignedIn
        }
        if !forceRefresh && !tokens.isExpired() { return tokens.accessToken }
        if let inFlight { return try await inFlight.value.accessToken }

        guard let refreshToken = tokens.refreshToken else { throw CalendarError.reauthenticationRequired }
        let request = URLRequest.formPost(url: GoogleOAuthConfiguration.tokenEndpoint, parameters: [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let http = self.http
        let task = Task { () throws -> OAuthTokens in
            do {
                return try await http.decode(OAuthTokenResponse.self, from: request).tokens(previousRefreshToken: refreshToken)
            } catch let error as NetworkError {
                throw Self.map(error)
            }
        }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        try store.setValue(fresh, for: SecureStoreKey.googleTokens)
        return fresh.accessToken
    }

    static func map(_ error: NetworkError) -> CalendarError {
        if let oauth = OAuthErrorResponse.parse(error.body) {
            switch oauth.error {
            case "invalid_grant": return .reauthenticationRequired
            case "invalid_client", "unauthorized_client": return .notConfigured
            default: return .api(status: error.statusCode ?? 0, message: oauth.errorDescription ?? oauth.error)
            }
        }
        return .network(error)
    }
}

enum PKCE {
    /// S256 code challenge: base64url(SHA256(verifier)) without padding (RFC 7636).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
