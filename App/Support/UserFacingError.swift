import BankKit
import Foundation
import Networking

/// Turns module errors into short, actionable messages.
struct UserFacingError: Equatable, Identifiable {
    enum Action: Equatable {
        case none
        case reconnectBank
        case openSettings
        case retry
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
        default:
            self.init(title: "Something went wrong", message: error.localizedDescription, action: .retry)
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
