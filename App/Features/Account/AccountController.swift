import AccountKit
import AuthenticationServices
import Foundation
import Observation
import SwiftUI

/// The signed-in DayLedger account and every way to sign in or out. Views call this; it talks to
/// `AuthServicing` (Supabase) and, in Debug builds only, handles the developer login.
@MainActor
@Observable
final class AccountController {
    private(set) var user: AuthUser?
    /// Debug-only local account ("admin"): no backend, no cloud sync, always subscribed.
    let isDeveloperAccount: Bool
    /// A password-reset link was opened: ask for a new password.
    var isChoosingNewPassword = false
    /// A problem with a link opened from an email (shown as an alert).
    var linkError: UserFacingError?
    /// A link from an email is being exchanged for a session.
    private(set) var isHandlingLink = false

    @ObservationIgnored let auth: AuthServicing
    /// Called after every successful sign-in (subscription check and cloud sync hook in here).
    @ObservationIgnored var onSignedIn: (@MainActor (AuthUser) -> Void)?
    @ObservationIgnored var onSignedOut: (@MainActor () -> Void)?
    /// Debug only: the developer account was signed in or out, so the app rebuilds its services.
    @ObservationIgnored var onDeveloperSessionChanged: (@MainActor () -> Void)?

    init(auth: AuthServicing, developerUser: AuthUser? = nil) {
        self.auth = auth
        isDeveloperAccount = developerUser != nil
        user = developerUser ?? auth.currentSession?.user
    }

    var isSignedIn: Bool { user != nil }
    /// False when `SUPABASE_URL` / `SUPABASE_ANON_KEY` are missing from the build.
    var isConfigured: Bool { auth.isConfigured }
    var email: String? { user?.email }

    // MARK: Email

    func signIn(email: String, password: String) async throws {
        #if DEBUG
        if DeveloperLogin.matches(email: email, password: password) {
            DeveloperLogin.setSignedIn(true)
            onDeveloperSessionChanged?()
            return
        }
        #endif
        try requireConfigured()
        let session = try await auth.signIn(email: email, password: password)
        didSignIn(session.user)
    }

    /// Returns the email address to check when the account needs confirming first.
    func signUp(email: String, password: String) async throws -> String? {
        try requireConfigured()
        switch try await auth.signUp(email: email, password: password) {
        case .signedIn(let session):
            didSignIn(session.user)
            return nil
        case .confirmationRequired(let email):
            return email
        }
    }

    func sendPasswordReset(email: String) async throws {
        try requireConfigured()
        try await auth.sendPasswordReset(email: email)
    }

    func updatePassword(_ password: String) async throws {
        try await auth.updatePassword(password)
        isChoosingNewPassword = false
    }

    // MARK: Apple and Google

    func signInWithApple(_ authorization: ASAuthorization, rawNonce: String?) async throws {
        try requireConfigured()
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let rawNonce else {
            throw AuthError.other("Apple didn't return a sign-in token. Please try again.")
        }
        let session = try await auth.signInWithApple(idToken: idToken, rawNonce: rawNonce)
        didSignIn(session.user)
    }

    /// Opens Supabase's Google sign-in page. Returns quietly if the user closes it.
    func signInWithGoogle(using session: WebAuthenticationSession) async throws {
        try requireConfigured()
        let request = try auth.makeGoogleAuthorizationRequest()
        let callbackURL: URL
        do {
            callbackURL = try await session.authenticate(
                using: request.url,
                callbackURLScheme: request.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        }
        let authSession = try await auth.completeOAuth(callbackURL: callbackURL, verifier: request.codeVerifier)
        didSignIn(authSession.user)
    }

    // MARK: Links

    /// True for `dayledger://auth-callback…` (email confirmation and password reset links).
    static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == SupabaseConfiguration.callbackScheme && url.host?.lowercased() == "auth-callback"
    }

    /// Handles an auth link. Returns false for other URLs (e.g. `dayledger://truelayer-callback`),
    /// which are left to whoever is waiting for them.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard Self.isAuthCallback(url) else { return false }
        guard !isDeveloperAccount, auth.isConfigured else { return true }
        isHandlingLink = true
        Task {
            defer { isHandlingLink = false }
            do {
                let result = try await auth.handleAuthCallback(url)
                didSignIn(result.session.user)
                if result.isPasswordRecovery { isChoosingNewPassword = true }
            } catch {
                linkError = UserFacingError.account(error)
            }
        }
        return true
    }

    // MARK: Signing out

    func signOut() async {
        #if DEBUG
        if isDeveloperAccount {
            DeveloperLogin.setSignedIn(false)
            user = nil
            onDeveloperSessionChanged?()
            return
        }
        #endif
        await auth.signOut()
        user = nil
        isChoosingNewPassword = false
        onSignedOut?()
    }

    /// The refresh token was rejected (signed out elsewhere, or the account was deleted).
    func sessionExpired() {
        guard !isDeveloperAccount, user != nil, auth.currentSession == nil else { return }
        user = nil
        onSignedOut?()
    }

    // MARK: Private

    private func requireConfigured() throws {
        guard auth.isConfigured else { throw AuthError.notConfigured }
    }

    private func didSignIn(_ user: AuthUser) {
        self.user = user
        onSignedIn?(user)
    }
}
