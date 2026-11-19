import AccountKit
import AIKit
import BankKit
import CalendarKit
import Foundation
import Networking

/// Turns module errors into short, actionable messages.
struct UserFacingError: Equatable, Identifiable {
    enum Action: Equatable {
        case none
        case reconnectBank
        case openSettings
        case retry
        case signInGoogle
    }

    var id: String { title + message }
    let title: String
    let message: String
    let action: Action

    init(title: String, message: String, action: Action = .none) {
        self.title = title
        self.message = message
        self.action = action
    }

    init(_ error: Error) {
        switch error {
        case let error as BankError:
            self = Self.bank(error)
        case let error as NetworkError:
            self = Self.network(error)
        case let error as CalendarError:
            self = Self.calendar(error)
        case let error as AIError:
            self = Self.ai(error)
        case let error as AuthError:
            self = Self.auth(error)
        default:
            self = UserFacingError(title: "Something went wrong", message: error.localizedDescription, action: .retry)
        }
    }

    static func network(_ error: NetworkError) -> UserFacingError {
        switch error {
        case .offline:
            return UserFacingError(title: "You're offline", message: "Showing saved data. Pull to refresh when you're back online.", action: .retry)
        case .timedOut:
            return UserFacingError(title: "The request timed out", message: "Check your connection and try again.", action: .retry)
        case .cancelled:
            return UserFacingError(title: "Cancelled", message: "The request was cancelled.")
        case .unauthorized, .forbidden:
            return UserFacingError(title: "Sign-in expired", message: "Please sign in again.", action: .reconnectBank)
        case .http(let status, _):
            return UserFacingError(title: "Server error", message: "The server returned an error (\(status)). Try again later.", action: .retry)
        case .invalidResponse, .decoding, .transport:
            return UserFacingError(title: "Unexpected response", message: "Something went wrong talking to the server. Try again later.", action: .retry)
        }
    }

    /// Account errors shown on the login screens.
    static func auth(_ error: AuthError) -> UserFacingError {
        switch error {
        case .invalidCredentials:
            return UserFacingError(title: "Couldn't log in", message: "That email and password don't match. Check them and try again.")
        case .emailNotConfirmed:
            return UserFacingError(title: "Confirm your email first", message: "Open the link we emailed you, then log in.")
        case .userAlreadyExists:
            return UserFacingError(title: "You already have an account", message: "Log in with that email instead, or reset your password.")
        case .weakPassword:
            return UserFacingError(title: "Choose a stronger password", message: "Use at least 8 characters. A few words together work well.")
        case .network(let error):
            return network(error)
        case .sessionExpired:
            return UserFacingError(title: "Please log in again", message: "Your session has ended.")
        case .notConfigured:
            return UserFacingError(title: "Accounts aren't set up yet",
                                   message: "This build has no account server. Add SUPABASE_URL and SUPABASE_ANON_KEY to Config/Local.xcconfig, then rebuild.")
        case .other(let message):
            return UserFacingError(title: "Something went wrong", message: message, action: .retry)
        }
    }

    /// Like `init(_:)`, for errors from the account and subscription screens.
    static func account(_ error: Error) -> UserFacingError {
        UserFacingError(error)
    }

    static func ai(_ error: AIError) -> UserFacingError {
        switch error {
        case .missingAPIKey:
            return UserFacingError(title: "No API key", message: "Add your API key in Settings → AI assistant.")
        case .invalidAPIKey:
            return UserFacingError(title: "API key rejected", message: "The provider didn't accept your API key. Check it in Settings → AI assistant.")
        case .rateLimited:
            return UserFacingError(title: "Rate limited", message: "Your API key has hit its rate limit. Try again in a minute.", action: .retry)
        case .overloaded:
            return UserFacingError(title: "AI service busy", message: "The provider is overloaded. Try again shortly.", action: .retry)
        case .refused:
            return UserFacingError(title: "No suggestions", message: "The AI declined this request. Nothing was changed.", action: .retry)
        case .truncated:
            return UserFacingError(title: "Response cut off", message: "The AI's answer was incomplete. Try again.", action: .retry)
        case .invalidResponse(let detail):
            return UserFacingError(title: "Couldn't read suggestions", message: detail, action: .retry)
        case .providerError(let status, let message):
            return UserFacingError(title: "AI provider error (\(status))", message: message, action: .retry)
        case .offline:
            return network(.offline)
        case .network(let detail):
            return UserFacingError(title: "Network error", message: detail, action: .retry)
        }
    }

    static func calendar(_ error: CalendarError) -> UserFacingError {
        switch error {
        case .notConfigured:
            return UserFacingError(title: "Google sign-in not set up",
                                   message: "Add your Google iOS client ID to Config/Local.xcconfig, then rebuild.")
        case .notSignedIn:
            return UserFacingError(title: "Not signed in to Google", message: "Sign in with Google to write to your calendar.", action: .signInGoogle)
        case .authorizationDenied(let reason):
            return UserFacingError(title: "Google sign-in declined", message: "Google didn't grant access (\(reason)).", action: .signInGoogle)
        case .stateMismatch:
            return UserFacingError(title: "Couldn't verify the Google sign-in", message: "Please try again.", action: .signInGoogle)
        case .reauthenticationRequired:
            return UserFacingError(title: "Sign in to Google again",
                                   message: "Your Google session expired. (Apps in Google's \"Testing\" mode expire sign-ins after 7 days.)",
                                   action: .signInGoogle)
        case .insufficientPermissions:
            return UserFacingError(title: "Calendar permission missing",
                                   message: "Sign in again and allow DayLedger to manage its own calendar.", action: .signInGoogle)
        case .calendarNotFound:
            return UserFacingError(title: "Calendar not found", message: "The DayLedger calendar will be recreated on the next sync.", action: .retry)
        case .rateLimited:
            return UserFacingError(title: "Google is busy", message: "Too many requests. DayLedger will try again later.", action: .retry)
        case .network(let error):
            return network(error)
        case .api(let status, let message):
            return UserFacingError(title: "Google Calendar error", message: message.isEmpty ? "Error \(status)." : message, action: .retry)
        }
    }

    static func bank(_ error: BankError) -> UserFacingError {
        switch error {
        case .notConfigured:
            return UserFacingError(title: "Bank connection not set up",
                                   message: "Add your TrueLayer client ID (and sandbox secret) to Config/Local.xcconfig, then rebuild.")
        case .notConnected:
            return UserFacingError(title: "No bank connected", message: "Connect a bank to see your spending.", action: .reconnectBank)
        case .authorizationCancelled:
            return UserFacingError(title: "Cancelled", message: "Bank connection was cancelled.")
        case .authorizationDenied(let reason):
            return UserFacingError(title: "Bank connection declined", message: "The bank didn't grant access (\(reason)).", action: .reconnectBank)
        case .stateMismatch:
            return UserFacingError(title: "Couldn't verify the bank login", message: "Please try connecting again.", action: .reconnectBank)
        case .reconnectRequired(let name):
            return UserFacingError(title: "Reconnect \(name ?? "your bank")",
                                   message: "Access has expired. UK banks ask you to re-confirm access every 90 days.",
                                   action: .reconnectBank)
        case .rateLimited:
            return UserFacingError(title: "Too many requests", message: "The bank is limiting requests. Try again in a few minutes.", action: .retry)
        case .network(let error):
            return network(error)
        case .providerError(let message):
            return UserFacingError(title: "Bank error", message: message, action: .retry)
        }
    }
}
