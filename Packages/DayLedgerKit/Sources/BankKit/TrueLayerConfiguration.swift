import Foundation
import Networking

public enum TrueLayerEnvironment: String, Sendable {
    case sandbox
    case live

    public var authBaseURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://auth.truelayer-sandbox.com")!
        case .live: return URL(string: "https://auth.truelayer.com")!
        }
    }

    public var apiBaseURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.truelayer-sandbox.com")!
        case .live: return URL(string: "https://api.truelayer.com")!
        }
    }

    /// Providers shown in TrueLayer's bank picker. "uk-cs-mock" is the sandbox Mock Bank.
    public var providers: String {
        switch self {
        case .sandbox: return "uk-cs-mock uk-ob-all uk-oauth-all"
        case .live: return "uk-ob-all uk-oauth-all"
        }
    }
}

public struct TrueLayerConfiguration: Sendable {
    public var clientID: String
    public var environment: TrueLayerEnvironment
    /// Must also be added to "Allowed redirect URIs" in the TrueLayer console.
    public var redirectURI: URL
    public var scopes: [String]

    public init(
        clientID: String,
        environment: TrueLayerEnvironment = .sandbox,
        redirectURI: URL = URL(string: "dayledger://truelayer-callback")!,
        scopes: [String] = ["info", "accounts", "balance", "cards", "transactions", "offline_access"]
    ) {
        self.clientID = clientID
        self.environment = environment
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var callbackURLScheme: String {
        redirectURI.scheme ?? "dayledger"
    }

    public func authorizationURL(state: String) -> URL {
        var components = URLComponents(url: environment.authBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "providers", value: environment.providers),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Extracts the authorization code from the redirect, validating `state`.
    public func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        if let error = OAuthCallback.queryValue("error", in: callbackURL) {
            throw BankError.authorizationDenied(error)
        }
        guard OAuthCallback.queryValue("state", in: callbackURL) == expectedState else {
            throw BankError.stateMismatch
        }
        guard let code = OAuthCallback.queryValue("code", in: callbackURL), !code.isEmpty else {
            throw BankError.authorizationDenied("missing_code")
        }
        return code
    }
}
