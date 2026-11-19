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
            self = UserFacingError(title: String(localized: "Something went wrong"), message: error.localizedDescription, action: .retry)
        }
    }

    static func network(_ error: NetworkError) -> UserFacingError {
        switch error {
        case .offline:
            return UserFacingError(title: String(localized: "You're offline"), message: String(localized: "Showing saved data. Pull to refresh when you're back online."), action: .retry)
        case .timedOut:
            return UserFacingError(title: String(localized: "The request timed out"), message: String(localized: "Check your connection and try again."), action: .retry)
        case .cancelled:
            return UserFacingError(title: String(localized: "Cancelled"), message: String(localized: "The request was cancelled."))
        case .unauthorized, .forbidden:
            return UserFacingError(title: String(localized: "Sign-in expired"), message: String(localized: "Please sign in again."), action: .reconnectBank)
        case .http(let status, _):
            return UserFacingError(title: String(localized: "Server error"), message: String(localized: "The server returned an error (\(status)). Try again later."), action: .retry)
        case .invalidResponse, .decoding, .transport:
            return UserFacingError(title: String(localized: "Unexpected response"), message: String(localized: "Something went wrong talking to the server. Try again later."), action: .retry)
        }
    }

    /// Account errors shown on the login screens.
    static func auth(_ error: AuthError) -> UserFacingError {
        switch error {
        case .invalidCredentials:
            return UserFacingError(title: String(localized: "Couldn't log in"), message: String(localized: "That email and password don't match. Check them and try again."))
        case .emailNotConfirmed:
            return UserFacingError(title: String(localized: "Confirm your email first"), message: String(localized: "Open the link we emailed you, then log in."))
        case .userAlreadyExists:
            return UserFacingError(title: String(localized: "You already have an account"), message: String(localized: "Log in with that email instead, or reset your password."))
        case .weakPassword:
            return UserFacingError(title: String(localized: "Choose a stronger password"), message: String(localized: "Use at least 8 characters. A few words together work well."))
        case .network(let error):
            return network(error)
        case .sessionExpired:
            return UserFacingError(title: String(localized: "Please log in again"), message: String(localized: "Your session has ended."))
        case .notConfigured:
            return UserFacingError(title: String(localized: "Accounts aren't set up yet"),
                                   message: String(localized: "This build has no account server. Add SUPABASE_URL and SUPABASE_ANON_KEY to Config/Local.xcconfig, then rebuild."))
        case .other(let message):
            return UserFacingError(title: String(localized: "Something went wrong"), message: message, action: .retry)
        }
    }

    /// Like `init(_:)`, for errors from the account and subscription screens.
    static func account(_ error: Error) -> UserFacingError {
        UserFacingError(error)
    }

    static func ai(_ error: AIError) -> UserFacingError {
        switch error {
        case .notEntitled:
            return UserFacingError(title: String(localized: "Part of DayLedger Pro"), message: String(localized: "AI suggestions need DayLedger Pro and an internet connection."))
        case .dailyLimitReached(let message):
            return UserFacingError(title: String(localized: "Daily limit reached"), message: message)
        case .rateLimited:
            return UserFacingError(title: String(localized: "Rate limited"), message: String(localized: "Too many requests. Try again in a minute."), action: .retry)
        case .overloaded:
            return UserFacingError(title: String(localized: "AI service busy"), message: String(localized: "The provider is overloaded. Try again shortly."), action: .retry)
        case .refused:
            return UserFacingError(title: String(localized: "No suggestions"), message: String(localized: "The AI declined this request. Nothing was changed."), action: .retry)
        case .truncated:
            return UserFacingError(title: String(localized: "Response cut off"), message: String(localized: "The AI's answer was incomplete. Try again."), action: .retry)
        case .invalidResponse(let detail):
            return UserFacingError(title: String(localized: "Couldn't read suggestions"), message: detail, action: .retry)
        case .providerError(let status, let message):
            return UserFacingError(title: String(localized: "AI provider error (\(status))"), message: message, action: .retry)
        case .offline:
            return network(.offline)
        case .network(let detail):
            return UserFacingError(title: String(localized: "Network error"), message: detail, action: .retry)
        }
    }

    static func calendar(_ error: CalendarError) -> UserFacingError {
        switch error {
        case .notConfigured:
            return UserFacingError(title: String(localized: "Google sign-in not set up"),
                                   message: String(localized: "Add your Google iOS client ID to Config/Local.xcconfig, then rebuild."))
        case .notSignedIn:
            return UserFacingError(title: String(localized: "Not signed in to Google"), message: String(localized: "Sign in with Google to write to your calendar."), action: .signInGoogle)
        case .authorizationDenied(let reason):
            return UserFacingError(title: String(localized: "Google sign-in declined"), message: String(localized: "Google didn't grant access (\(reason))."), action: .signInGoogle)
        case .stateMismatch:
            return UserFacingError(title: String(localized: "Couldn't verify the Google sign-in"), message: String(localized: "Please try again."), action: .signInGoogle)
        case .reauthenticationRequired:
            return UserFacingError(title: String(localized: "Sign in to Google again"),
                                   message: String(localized: "Your Google session expired. (Apps in Google's \"Testing\" mode expire sign-ins after 7 days.)"),
                                   action: .signInGoogle)
        case .insufficientPermissions:
            return UserFacingError(title: String(localized: "Calendar permission missing"),
                                   message: String(localized: "Sign in again and allow DayLedger to manage its own calendar."), action: .signInGoogle)
        case .calendarNotFound:
            return UserFacingError(title: String(localized: "Calendar not found"), message: String(localized: "The DayLedger calendar will be recreated on the next sync."), action: .retry)
        case .calendarAccessDenied:
            return UserFacingError(title: String(localized: "Calendar access needed"),
                                   message: String(localized: "Allow DayLedger full access to your calendars in Settings, so it can keep its own DayLedger calendar up to date."),
                                   action: .openSettings)
        case .rateLimited:
            return UserFacingError(title: String(localized: "Google is busy"), message: String(localized: "Too many requests. DayLedger will try again later."), action: .retry)
        case .network(let error):
            return network(error)
        case .api(let status, let message):
            return UserFacingError(title: String(localized: "Google Calendar error"), message: message.isEmpty ? String(localized: "Error \(status).") : message, action: .retry)
        }
    }

    static func bank(_ error: BankError) -> UserFacingError {
        switch error {
        case .notConfigured:
            return UserFacingError(title: String(localized: "Bank connection not set up"),
                                   message: String(localized: "Add your TrueLayer client ID (and sandbox secret) to Config/Local.xcconfig, then rebuild."))
        case .notConnected:
            return UserFacingError(title: String(localized: "No bank connected"), message: String(localized: "Connect a bank to see your spending."), action: .reconnectBank)
        case .authorizationCancelled:
            return UserFacingError(title: String(localized: "Cancelled"), message: String(localized: "Bank connection was cancelled."))
        case .authorizationDenied(let reason):
            return UserFacingError(title: String(localized: "Bank connection declined"), message: String(localized: "The bank didn't grant access (\(reason))."), action: .reconnectBank)
        case .stateMismatch:
            return UserFacingError(title: String(localized: "Couldn't verify the bank login"), message: String(localized: "Please try connecting again."), action: .reconnectBank)
        case .reconnectRequired(let name):
            return UserFacingError(title: name.map { String(localized: "Reconnect \($0)") } ?? String(localized: "Reconnect your bank"),
                                   message: String(localized: "Access has expired. UK banks ask you to re-confirm access every 90 days."),
                                   action: .reconnectBank)
        case .rateLimited:
            return UserFacingError(title: String(localized: "Too many requests"), message: String(localized: "The bank is limiting requests. Try again in a few minutes."), action: .retry)
        case .network(let error):
            return network(error)
        case .providerError(let message):
            return UserFacingError(title: String(localized: "Bank error"), message: message, action: .retry)
        }
    }
}
