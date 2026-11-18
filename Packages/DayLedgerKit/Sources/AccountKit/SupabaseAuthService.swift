import Foundation
import Networking
import SecureStore

/// Gives API clients a valid access token without knowing how sessions are stored or refreshed.
public protocol AccessTokenProviding: AnyObject, Sendable {
    /// The current access token, refreshed first if it has expired.
    func validAccessToken() async throws -> String
    /// Called after the server rejected `rejectedToken` (HTTP 401). Refreshes once, even when
    /// several requests fail at the same time, and returns the new token.
    func refreshedAccessToken(after rejectedToken: String) async throws -> String
}

/// Everything the app needs from the account backend. `SupabaseAuthService` is the real one;
/// `MockAuthService` backs previews and tests.
public protocol AuthServicing: AccessTokenProviding {
    /// False when `SUPABASE_URL` / `SUPABASE_ANON_KEY` are missing.
    var isConfigured: Bool { get }
    /// The stored session, if any. It may be expired: use `validAccessToken()` before calling the API.
    var currentSession: AuthSession? { get }

    func signUp(email: String, password: String) async throws -> SignUpResult
    func signIn(email: String, password: String) async throws -> AuthSession
    func sendPasswordReset(email: String) async throws
    /// `idToken` from `ASAuthorizationAppleIDCredential.identityToken`; `rawNonce` is the
    /// unhashed nonce whose SHA-256 was put on the Apple request.
    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthSession
    /// Google via Supabase's hosted OAuth page. Open `url` in `ASWebAuthenticationSession`.
    func makeGoogleAuthorizationRequest() throws -> OAuthAuthorizationRequest
    func completeOAuth(callbackURL: URL, verifier: String) async throws -> AuthSession
    /// Handles `dayledger://auth-callback?code=…` from a confirmation or password-reset email.
    func handleAuthCallback(_ url: URL) async throws -> AuthCallbackResult
    func updatePassword(_ newPassword: String) async throws
    /// Best effort `/logout`, then always forgets the session on this device.
    func signOut() async
}

public extension AuthServicing {
    var isSignedIn: Bool { currentSession != nil }
}

/// Supabase Auth (GoTrue) over plain `URLSession`, as described in docs/backend-contract.md.
/// The session lives only in the Keychain.
public final class SupabaseAuthService: AuthServicing, @unchecked Sendable {
    public let configuration: SupabaseConfiguration
    private let store: SecureStoring
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private let refresher: SessionRefresher

    public init(
        configuration: SupabaseConfiguration,
        store: SecureStoring,
        http: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.http = http
        self.now = now
        refresher = SessionRefresher(configuration: configuration, store: store, http: http, now: now)
    }

    public var isConfigured: Bool { configuration.isConfigured }

    public var currentSession: AuthSession? {
        (try? store.value(AuthSession.self, for: SecureStoreKey.supabaseSession)) ?? nil
    }

    // MARK: Email and password

    public func signUp(email: String, password: String) async throws -> SignUpResult {
        let email = Self.normalise(email)
        // PKCE for the confirmation link: the email brings back `?code=`, exchanged with this verifier.
        let verifier = SupabasePKCE.makeVerifier()
        let url = try configuration.endpoint("auth/v1/signup", query: [URLQueryItem(name: "redirect_to", value: SupabaseConfiguration.authCallbackURL)])
        let request = try makeJSONRequest(url: url, body: [
            "email": email,
            "password": password,
            "code_challenge": SupabasePKCE.challenge(for: verifier),
            "code_challenge_method": "s256",
        ])
        try savePendingLink(PendingEmailLink(codeVerifier: verifier, purpose: .signUp, createdAt: now()))
        let dto = try await send(request, decoding: GoTrueSessionDTO.self)
        if let session = dto.session(now: now()) {
            try save(session)
            try? store.remove(SecureStoreKey.supabasePendingEmailLink)
            return .signedIn(session)
        }
        return .confirmationRequired(email: email)
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let url = try configuration.endpoint("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")])
        let request = try makeJSONRequest(url: url, body: ["email": Self.normalise(email), "password": password])
        return try await exchange(request)
    }

    public func sendPasswordReset(email: String) async throws {
        let verifier = SupabasePKCE.makeVerifier()
        let url = try configuration.endpoint("auth/v1/recover", query: [URLQueryItem(name: "redirect_to", value: SupabaseConfiguration.authCallbackURL)])
        let request = try makeJSONRequest(url: url, body: [
            "email": Self.normalise(email),
            "code_challenge": SupabasePKCE.challenge(for: verifier),
            "code_challenge_method": "s256",
        ])
        try savePendingLink(PendingEmailLink(codeVerifier: verifier, purpose: .recovery, createdAt: now()))
        _ = try await sendRaw(request)
    }

    public func updatePassword(_ newPassword: String) async throws {
        let token = try await validAccessToken()
        let url = try configuration.endpoint("auth/v1/user")
        var request = try makeJSONRequest(url: url, body: ["password": newPassword])
        request.httpMethod = "PUT"
        request.setBearer(token)
        _ = try await sendRaw(request)
    }

    // MARK: Apple and Google

    public func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthSession {
        let url = try configuration.endpoint("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "id_token")])
        let request = try makeJSONRequest(url: url, body: ["provider": "apple", "id_token": idToken, "nonce": rawNonce])
        return try await exchange(request)
    }

    public func makeGoogleAuthorizationRequest() throws -> OAuthAuthorizationRequest {
        let verifier = SupabasePKCE.makeVerifier()
        let url = try configuration.endpoint("auth/v1/authorize", query: [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: SupabaseConfiguration.authCallbackURL),
            URLQueryItem(name: "code_challenge", value: SupabasePKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ])
        return OAuthAuthorizationRequest(url: url, callbackScheme: SupabaseConfiguration.callbackScheme, codeVerifier: verifier)
    }

    public func completeOAuth(callbackURL: URL, verifier: String) async throws -> AuthSession {
        let code = try Self.authCode(from: callbackURL)
        return try await exchangeCode(code, verifier: verifier)
    }

    public func handleAuthCallback(_ url: URL) async throws -> AuthCallbackResult {
        let code = try Self.authCode(from: url)
        guard let pending = try? store.value(PendingEmailLink.self, for: SecureStoreKey.supabasePendingEmailLink) else {
            // The link was requested on another device (or the app was reinstalled since).
            throw AuthError.other(AuthError.linkExpiredMessage)
        }
        let session = try await exchangeCode(code, verifier: pending.codeVerifier)
        try? store.remove(SecureStoreKey.supabasePendingEmailLink)
        let type = OAuthCallback.queryValue("type", in: url)
        return AuthCallbackResult(session: session, isPasswordRecovery: pending.purpose == .recovery || type == "recovery")
    }

    // MARK: Tokens

    public func validAccessToken() async throws -> String {
        try await refresher.validSession().accessToken
    }

    public func refreshedAccessToken(after rejectedToken: String) async throws -> String {
        try await refresher.refreshedSession(after: rejectedToken).accessToken
    }

    /// Forces a refresh, e.g. to pick up new claims.
    public func refreshSession() async throws -> AuthSession {
        try await refresher.refreshedSession(after: currentSession?.accessToken ?? "")
    }

    public func signOut() async {
        if let session = currentSession, isConfigured, let url = try? configuration.endpoint("auth/v1/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
            request.setBearer(session.accessToken)
            _ = try? await http.send(request)
        }
        try? store.remove(SecureStoreKey.supabaseSession)
        try? store.remove(SecureStoreKey.supabasePendingEmailLink)
    }

    // MARK: Helpers

    static func normalise(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Reads `?code=` from a callback, turning `?error=…&error_description=…` into an `AuthError`.
    static func authCode(from url: URL) throws -> String {
        // GoTrue puts errors in the query or, for some flows, in the fragment.
        var fragmentItems: [URLQueryItem] = []
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment {
            var components = URLComponents()
            components.query = fragment
            fragmentItems = components.queryItems ?? []
        }
        func value(_ name: String) -> String? {
            OAuthCallback.queryValue(name, in: url) ?? fragmentItems.first { $0.name == name }?.value
        }
        if let error = value("error") {
            let code = value("error_code") ?? error
            if code == "otp_expired" || code == "flow_state_expired" || code == "flow_state_not_found" {
                throw AuthError.other(AuthError.linkExpiredMessage)
            }
            if code == "access_denied" && value("error_description") == nil {
                throw AuthError.other("Sign-in was cancelled.")
            }
            throw AuthError.other(value("error_description") ?? error)
        }
        guard let code = OAuthCallback.queryValue("code", in: url), !code.isEmpty else {
            throw AuthError.other("The sign-in link is incomplete. Please try again.")
        }
        return code
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> AuthSession {
        let url = try configuration.endpoint("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "pkce")])
        let request = try makeJSONRequest(url: url, body: ["auth_code": code, "code_verifier": verifier])
        return try await exchange(request)
    }

    /// Sends a token request and stores the resulting session.
    private func exchange(_ request: URLRequest) async throws -> AuthSession {
        let dto = try await send(request, decoding: GoTrueSessionDTO.self)
        guard let session = dto.session(now: now()) else {
            throw AuthError.other("The server didn't return a session.")
        }
        try save(session)
        return session
    }

    private func save(_ session: AuthSession) throws {
        do {
            try store.setValue(session, for: SecureStoreKey.supabaseSession)
        } catch {
            throw AuthError.other("Couldn't save your sign-in to the Keychain.")
        }
    }

    private func savePendingLink(_ link: PendingEmailLink) throws {
        try? store.setValue(link, for: SecureStoreKey.supabasePendingEmailLink)
    }

    private func makeJSONRequest(url: URL, body: [String: String]) throws -> URLRequest {
        try SupabaseRequest.json(url: url, body: body, anonKey: configuration.anonKey)
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthError.other("The server sent an unexpected response.")
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        do {
            return try await http.sendValidated(request)
        } catch let error as NetworkError {
            throw AuthError.map(error)
        }
    }
}

enum SupabaseRequest {
    static func json(url: URL, body: [String: String], anonKey: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// Serialises session refreshes so concurrent API calls share one refresh (GoTrue rotates refresh
/// tokens, so two parallel refreshes with the same token would sign the user out).
actor SessionRefresher {
    private let configuration: SupabaseConfiguration
    private let store: SecureStoring
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private var inFlight: Task<AuthSession, Error>?

    init(configuration: SupabaseConfiguration, store: SecureStoring, http: HTTPClient, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration
        self.store = store
        self.http = http
        self.now = now
    }

    private func storedSession() throws -> AuthSession {
        guard let session = (try? store.value(AuthSession.self, for: SecureStoreKey.supabaseSession)) ?? nil else {
            throw AuthError.sessionExpired
        }
        return session
    }

    /// The stored session, refreshed first if its access token has (nearly) expired.
    func validSession() async throws -> AuthSession {
        if let inFlight { return try await inFlight.value }
        let session = try storedSession()
        if !session.isExpired(now: now()) { return session }
        return try await refresh(session)
    }

    /// Refreshes unless another caller already replaced `rejectedToken`.
    func refreshedSession(after rejectedToken: String) async throws -> AuthSession {
        if let inFlight { return try await inFlight.value }
        let session = try storedSession()
        if session.accessToken != rejectedToken && !session.isExpired(now: now()) { return session }
        return try await refresh(session)
    }

    private func refresh(_ session: AuthSession) async throws -> AuthSession {
        guard configuration.isConfigured, let url = try? configuration.endpoint("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")]) else {
            throw AuthError.notConfigured
        }
        let request = try SupabaseRequest.json(url: url, body: ["refresh_token": session.refreshToken], anonKey: configuration.anonKey)
        let http = self.http
        let store = self.store
        let now = self.now
        let task = Task { () throws -> AuthSession in
            do {
                let data = try await http.sendValidated(request)
                guard let dto = try? JSONDecoder().decode(GoTrueSessionDTO.self, from: data),
                      let fresh = dto.session(now: now(), previousRefreshToken: session.refreshToken, fallbackUser: session.user) else {
                    throw AuthError.other("The server sent an unexpected response.")
                }
                try store.setValue(fresh, for: SecureStoreKey.supabaseSession)
                return fresh
            } catch let error as NetworkError {
                let mapped = AuthError.map(error, duringRefresh: true)
                if mapped == .sessionExpired {
                    // The refresh token is dead: forget it so the app shows the sign-in screen.
                    try? store.remove(SecureStoreKey.supabaseSession)
                }
                throw mapped
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
