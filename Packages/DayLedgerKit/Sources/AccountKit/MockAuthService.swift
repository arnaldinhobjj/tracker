import Foundation

/// An in-memory `AuthServicing` for previews and tests. Never talks to the network.
public final class MockAuthService: AuthServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?
    private var _isConfigured: Bool
    private var _calls: [String] = []

    /// Returned by `signIn`/`signInWithApple`/`completeOAuth` when set; otherwise they succeed.
    public var nextError: AuthError? {
        get { lock.withLock { _nextError } }
        set { lock.withLock { _nextError = newValue } }
    }
    private var _nextError: AuthError?

    /// When true, `signUp` asks for email confirmation instead of signing in.
    public var requiresEmailConfirmation: Bool {
        get { lock.withLock { _requiresEmailConfirmation } }
        set { lock.withLock { _requiresEmailConfirmation = newValue } }
    }
    private var _requiresEmailConfirmation = false

    public init(session: AuthSession? = nil, isConfigured: Bool = true) {
        self.session = session
        _isConfigured = isConfigured
    }

    /// The names of the methods called so far, in order.
    public var calls: [String] { lock.withLock { _calls } }

    public var isConfigured: Bool { lock.withLock { _isConfigured } }
    public var currentSession: AuthSession? { lock.withLock { session } }

    public static func makeSession(email: String = "test@example.com", userID: UUID = UUID(), expiresIn: TimeInterval = 3600) -> AuthSession {
        AuthSession(accessToken: "access-\(UUID().uuidString)", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expiresIn),
                    userID: userID, email: email)
    }

    private func record(_ call: String) throws {
        let (configured, error): (Bool, AuthError?) = lock.withLock {
            _calls.append(call)
            let error = _nextError
            _nextError = nil
            return (_isConfigured, error)
        }
        guard configured else { throw AuthError.notConfigured }
        if let error { throw error }
    }

    private func signInAs(_ email: String?) -> AuthSession {
        let new = Self.makeSession(email: email ?? "test@example.com")
        lock.withLock { session = new }
        return new
    }

    public func signUp(email: String, password: String) async throws -> SignUpResult {
        try record("signUp")
        if requiresEmailConfirmation { return .confirmationRequired(email: email) }
        return .signedIn(signInAs(email))
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try record("signIn")
        return signInAs(email)
    }

    public func sendPasswordReset(email: String) async throws {
        try record("sendPasswordReset")
    }

    public func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthSession {
        try record("signInWithApple")
        return signInAs(nil)
    }

    public func makeGoogleAuthorizationRequest() throws -> OAuthAuthorizationRequest {
        guard isConfigured else { throw AuthError.notConfigured }
        return OAuthAuthorizationRequest(url: URL(string: "https://example.invalid/auth/v1/authorize?provider=google")!,
                                         callbackScheme: SupabaseConfiguration.callbackScheme, codeVerifier: "verifier")
    }

    public func completeOAuth(callbackURL: URL, verifier: String) async throws -> AuthSession {
        try record("completeOAuth")
        return signInAs(nil)
    }

    public func handleAuthCallback(_ url: URL) async throws -> AuthCallbackResult {
        try record("handleAuthCallback")
        return AuthCallbackResult(session: signInAs(nil), isPasswordRecovery: OAuthCallbackType.isRecovery(url))
    }

    public func updatePassword(_ newPassword: String) async throws {
        try record("updatePassword")
    }

    public func validAccessToken() async throws -> String {
        guard let session = currentSession else { throw AuthError.sessionExpired }
        return session.accessToken
    }

    public func refreshedAccessToken(after rejectedToken: String) async throws -> String {
        let refreshed: AuthSession? = lock.withLock {
            guard var current = session else { return nil }
            _calls.append("refresh")
            current.accessToken = "access-\(UUID().uuidString)"
            session = current
            return current
        }
        guard let refreshed else { throw AuthError.sessionExpired }
        return refreshed.accessToken
    }

    public func signOut() async {
        lock.withLock {
            _calls.append("signOut")
            session = nil
        }
    }
}

enum OAuthCallbackType {
    static func isRecovery(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "type" && $0.value == "recovery" } ?? false
    }
}
