import Foundation
import Networking

/// Everything that can go wrong signing in, mapped from Supabase Auth (GoTrue) responses.
public enum AuthError: Error, Equatable, Sendable {
    case invalidCredentials
    case emailNotConfirmed
    case userAlreadyExists
    case weakPassword
    /// No connection, timeout or another transport failure.
    case network(NetworkError)
    /// The refresh token was rejected (signed out elsewhere, account deleted, or too old). Log in again.
    case sessionExpired
    /// `SUPABASE_URL` / `SUPABASE_ANON_KEY` are missing.
    case notConfigured
    case other(String)

    /// Maps a failed GoTrue call. Understands both error shapes GoTrue uses:
    /// `{"error_code":"invalid_credentials","msg":"…"}` (current) and
    /// `{"error":"invalid_grant","error_description":"…"}` (older OAuth-style).
    public static func map(_ error: NetworkError, duringRefresh: Bool = false) -> AuthError {
        switch error {
        case .offline, .timedOut, .cancelled, .transport, .invalidResponse:
            return .network(error)
        case .decoding:
            return .other("The server sent an unexpected response.")
        case .unauthorized, .forbidden, .http:
            break
        }

        let body = GoTrueErrorBody.parse(error.body)
        let code = (body?.errorCode ?? body?.error ?? "").lowercased()
        let message = body?.msg ?? body?.errorDescription ?? body?.message ?? ""
        let lowered = message.lowercased()

        switch code {
        case "invalid_credentials":
            return .invalidCredentials
        case "email_not_confirmed":
            return .emailNotConfirmed
        case "user_already_exists", "email_exists", "identity_already_exists":
            return .userAlreadyExists
        case "weak_password":
            return .weakPassword
        case "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired", "bad_jwt", "user_not_found":
            return .sessionExpired
        case "over_request_rate_limit", "over_email_send_rate_limit", "over_sms_send_rate_limit":
            return .other("Too many attempts. Please wait a minute and try again.")
        case "signup_disabled", "email_provider_disabled", "provider_disabled":
            return .other("This sign-in method isn't available at the moment.")
        case "flow_state_not_found", "flow_state_expired", "bad_code_verifier":
            return .other(AuthError.linkExpiredMessage)
        default:
            break
        }

        if lowered.contains("email not confirmed") { return .emailNotConfirmed }
        if lowered.contains("invalid login credentials") { return .invalidCredentials }
        if lowered.contains("already registered") || lowered.contains("already been registered") { return .userAlreadyExists }
        if lowered.contains("password should") || lowered.contains("weak password") { return .weakPassword }
        if lowered.contains("invalid api key") || lowered.contains("no api key") { return .notConfigured }
        if lowered.contains("refresh token") { return .sessionExpired }
        if duringRefresh, code == "invalid_grant" || error.statusCode == 400 || error.statusCode == 401 {
            return .sessionExpired
        }
        if message.isEmpty {
            return .other("The server returned an error (\(error.statusCode ?? 0)).")
        }
        return .other(message)
    }

    static let linkExpiredMessage = "That link has expired or was opened on a different device. Log in with your email and password instead."
}

/// The union of GoTrue's error body shapes. `code` is a number in GoTrue, so it is not decoded.
struct GoTrueErrorBody: Decodable {
    let errorCode: String?
    let msg: String?
    let message: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case msg
        case message
        case error
        case errorDescription = "error_description"
    }

    static func parse(_ body: String?) -> GoTrueErrorBody? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoTrueErrorBody.self, from: data)
    }
}
