import XCTest
@testable import AccountKit
import Networking
import SecureStore

final class SupabaseAuthServiceTests: XCTestCase {
    let configuration = SupabaseConfiguration(urlString: "https://abc.supabase.co/", anonKey: "anon-key")
    let userID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func tokenJSON(access: String = "access-1", refresh: String = "refresh-1", expiresIn: Int = 3600) -> String {
        #"{"access_token":"\#(access)","token_type":"bearer","expires_in":\#(expiresIn),"refresh_token":"\#(refresh)","user":{"id":"\#(userID.uuidString.lowercased())","email":"ana@example.com"}}"#
    }

    private func makeService(http: StubHTTPClient, store: InMemorySecureStore = InMemorySecureStore()) -> SupabaseAuthService {
        SupabaseAuthService(configuration: configuration, store: store, http: http)
    }

    // MARK: Configuration

    func testConfigurationNeedsURLAndKey() {
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertFalse(SupabaseConfiguration(urlString: "", anonKey: "k").isConfigured)
        XCTAssertFalse(SupabaseConfiguration(urlString: "https://abc.supabase.co", anonKey: " ").isConfigured)
        XCTAssertFalse(SupabaseConfiguration(urlString: "http://abc.supabase.co", anonKey: "k").isConfigured)
        XCTAssertTrue(SupabaseConfiguration(urlString: "http://localhost:54321", anonKey: "k").isConfigured)
    }

    func testUnconfiguredServiceThrowsNotConfigured() async {
        let service = SupabaseAuthService(configuration: SupabaseConfiguration(urlString: "", anonKey: ""), store: InMemorySecureStore(), http: StubHTTPClient())
        do {
            _ = try await service.signIn(email: "a@b.com", password: "password1")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .notConfigured)
        }
    }

    // MARK: Email sign-in

    func testSignInSuccessStoresSessionInKeychain() async throws {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", body: tokenJSON())
        let store = InMemorySecureStore()
        let service = makeService(http: http, store: store)

        let session = try await service.signIn(email: "  Ana@Example.com ", password: "correct horse")

        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.userID, userID)
        XCTAssertEqual(session.email, "ana@example.com")
        XCTAssertEqual(try store.value(AuthSession.self, for: SecureStoreKey.supabaseSession), session)
        XCTAssertEqual(service.currentSession, session)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.queryValue("grant_type"), "password")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(request.jsonBody()?["email"] as? String, "ana@example.com")
        XCTAssertEqual(request.jsonBody()?["password"] as? String, "correct horse")
    }

    func testInvalidCredentials() async {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", status: 400, body: #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
        do {
            _ = try await makeService(http: http).signIn(email: "a@b.com", password: "wrong")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testInvalidCredentialsOlderErrorShape() async {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", status: 400, body: #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#)
        do {
            _ = try await makeService(http: http).signIn(email: "a@b.com", password: "wrong")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testEmailNotConfirmed() async {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", status: 400, body: #"{"code":400,"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#)
        do {
            _ = try await makeService(http: http).signIn(email: "a@b.com", password: "password1")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .emailNotConfirmed)
        }
    }

    func testErrorMapping() {
        func map(_ status: Int, _ body: String) -> AuthError {
            AuthError.map(.http(status: status, body: body))
        }
        XCTAssertEqual(map(422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#), .userAlreadyExists)
        XCTAssertEqual(map(422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 8 characters."}"#), .weakPassword)
        XCTAssertEqual(map(400, #"{"msg":"User already registered"}"#), .userAlreadyExists)
        XCTAssertEqual(AuthError.map(.offline), .network(.offline))
        XCTAssertEqual(AuthError.map(.http(status: 400, body: #"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#),
                                     duringRefresh: true), .sessionExpired)
        XCTAssertEqual(map(500, #"{"msg":"Database error saving new user"}"#), .other("Database error saving new user"))
    }

    // MARK: Sign-up

    func testSignUpNeedsEmailConfirmation() async throws {
        let http = StubHTTPClient()
        // With "Confirm email" on, GoTrue returns the bare user and no tokens.
        http.on("/auth/v1/signup", body: #"{"id":"\#(userID.uuidString.lowercased())","email":"ana@example.com","confirmation_sent_at":"2026-11-18T10:00:00Z"}"#)
        let store = InMemorySecureStore()
        let service = makeService(http: http, store: store)

        let result = try await service.signUp(email: "ana@example.com", password: "long enough 1")

        XCTAssertEqual(result, .confirmationRequired(email: "ana@example.com"))
        XCTAssertNil(service.currentSession)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.queryValue("redirect_to"), "dayledger://auth-callback")
        XCTAssertEqual(request.jsonBody()?["code_challenge_method"] as? String, "s256")
        let challenge = try XCTUnwrap(request.jsonBody()?["code_challenge"] as? String)
        // The verifier for the emailed link is kept, and matches the challenge that was sent.
        let pending = try XCTUnwrap(store.value(PendingEmailLink.self, for: SecureStoreKey.supabasePendingEmailLink))
        XCTAssertEqual(SupabasePKCE.challenge(for: pending.codeVerifier), challenge)

        // Opening the link exchanges the code with that verifier.
        http.on("/auth/v1/token", body: tokenJSON())
        let callback = try await service.handleAuthCallback(URL(string: "dayledger://auth-callback?code=abc123")!)
        XCTAssertFalse(callback.isPasswordRecovery)
        XCTAssertEqual(callback.session.userID, userID)
        let exchange = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(exchange.queryValue("grant_type"), "pkce")
        XCTAssertEqual(exchange.jsonBody()?["auth_code"] as? String, "abc123")
        XCTAssertEqual(exchange.jsonBody()?["code_verifier"] as? String, pending.codeVerifier)
        XCTAssertNil(try store.data(for: SecureStoreKey.supabasePendingEmailLink))
    }

    func testSignUpWithoutConfirmationSignsIn() async throws {
        let http = StubHTTPClient()
        http.on("/auth/v1/signup", body: tokenJSON())
        let result = try await makeService(http: http).signUp(email: "ana@example.com", password: "long enough 1")
        guard case .signedIn(let session) = result else { return XCTFail("expected a session") }
        XCTAssertEqual(session.refreshToken, "refresh-1")
    }

    func testCallbackErrorIsReported() async {
        let service = makeService(http: StubHTTPClient())
        do {
            _ = try await service.handleAuthCallback(URL(string: "dayledger://auth-callback?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid")!)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .other(AuthError.linkExpiredMessage))
        }
    }

    // MARK: Apple and Google

    func testAppleSendsIDTokenWithRawNonce() async throws {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", body: tokenJSON())
        _ = try await makeService(http: http).signInWithApple(idToken: "apple.jwt.token", rawNonce: "raw-nonce")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.queryValue("grant_type"), "id_token")
        XCTAssertEqual(request.jsonBody()?["provider"] as? String, "apple")
        XCTAssertEqual(request.jsonBody()?["id_token"] as? String, "apple.jwt.token")
        XCTAssertEqual(request.jsonBody()?["nonce"] as? String, "raw-nonce", "Supabase gets the raw nonce; Apple got its hash")
    }

    func testNonceHashIsLowercaseHexSHA256() {
        XCTAssertEqual(AppleSignInNonce.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let nonce = AppleSignInNonce.makeRawNonce()
        XCTAssertEqual(nonce.count, 32)
        XCTAssertNotEqual(nonce, AppleSignInNonce.makeRawNonce())
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        XCTAssertEqual(SupabasePKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGoogleAuthorizationURLAndExchange() async throws {
        let http = StubHTTPClient()
        let service = makeService(http: http)
        let request = try service.makeGoogleAuthorizationRequest()

        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "abc.supabase.co")
        XCTAssertEqual(components.path, "/auth/v1/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["provider"], "google")
        XCTAssertEqual(items["redirect_to"], "dayledger://auth-callback")
        XCTAssertEqual(items["code_challenge_method"], "s256")
        XCTAssertEqual(items["code_challenge"], SupabasePKCE.challenge(for: request.codeVerifier))
        XCTAssertEqual(request.callbackScheme, "dayledger")

        http.on("/auth/v1/token", body: tokenJSON())
        let session = try await service.completeOAuth(callbackURL: URL(string: "dayledger://auth-callback?code=google-code")!, verifier: request.codeVerifier)
        XCTAssertEqual(session.userID, userID)
        let exchange = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(exchange.queryValue("grant_type"), "pkce")
        XCTAssertEqual(exchange.jsonBody()?["auth_code"] as? String, "google-code")
        XCTAssertEqual(exchange.jsonBody()?["code_verifier"] as? String, request.codeVerifier)
    }

    // MARK: Refresh

    func testConcurrentRefreshesAreCoalesced() async throws {
        let http = StubHTTPClient()
        http.delayNanoseconds = 100_000_000
        http.on("/auth/v1/token", body: tokenJSON(access: "fresh", refresh: "refresh-2"))
        let store = InMemorySecureStore()
        try store.setValue(AuthSession(accessToken: "old", refreshToken: "refresh-1", expiresAt: .distantPast, userID: userID, email: "ana@example.com"),
                           for: SecureStoreKey.supabaseSession)
        let service = makeService(http: http, store: store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 {
                group.addTask { try await service.validAccessToken() }
            }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }

        XCTAssertEqual(tokens, Array(repeating: "fresh", count: 5))
        XCTAssertEqual(http.requests(to: "/auth/v1/token").count, 1, "One refresh shared by every caller")
        XCTAssertEqual(http.requests.first?.jsonBody()?["refresh_token"] as? String, "refresh-1")
        XCTAssertEqual(service.currentSession?.refreshToken, "refresh-2")
    }

    func testRejectedRefreshTokenSignsOut() async throws {
        let http = StubHTTPClient()
        http.on("/auth/v1/token", status: 400, body: #"{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}"#)
        let store = InMemorySecureStore()
        try store.setValue(AuthSession(accessToken: "old", refreshToken: "r", expiresAt: .distantPast, userID: userID, email: nil),
                           for: SecureStoreKey.supabaseSession)
        let service = makeService(http: http, store: store)
        do {
            _ = try await service.validAccessToken()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        XCTAssertNil(service.currentSession)
    }

    func testRESTRetriesOnceAfter401WithRefreshedToken() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecureStore()
        try store.setValue(AuthSession(accessToken: "revoked", refreshToken: "refresh-1", expiresAt: .distantFuture, userID: userID, email: nil),
                           for: SecureStoreKey.supabaseSession)
        let auth = makeService(http: http, store: store)
        let rest = SupabaseRESTClient(configuration: configuration, tokens: auth, http: http)

        http.on("/rest/v1/rpc/has_active_entitlement", status: 401, body: #"{"message":"JWT expired"}"#)
        http.on("/auth/v1/token", body: tokenJSON(access: "fresh"))
        http.on("/rest/v1/rpc/has_active_entitlement", body: "true")

        let active = try await rest.hasActiveEntitlement()

        XCTAssertTrue(active)
        let calls = http.requests(to: "/rpc/has_active_entitlement")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.value(forHTTPHeaderField: "Authorization"), "Bearer revoked")
        XCTAssertEqual(calls.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(calls.last?.value(forHTTPHeaderField: "apikey"), "anon-key")
    }

    // MARK: Sign-out

    func testSignOutClearsKeychainEvenWhenLogoutFails() async throws {
        let http = StubHTTPClient() // No reply queued: /logout fails as if offline.
        let store = InMemorySecureStore()
        try store.setValue(MockAuthService.makeSession(), for: SecureStoreKey.supabaseSession)
        let service = makeService(http: http, store: store)

        await service.signOut()

        XCTAssertNil(service.currentSession)
        XCTAssertEqual(http.requests.first?.url?.path, "/auth/v1/logout")
    }
}
