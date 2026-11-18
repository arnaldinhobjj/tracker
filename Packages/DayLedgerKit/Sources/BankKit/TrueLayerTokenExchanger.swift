import Foundation
import Networking

/// Swaps an authorization code for tokens and refreshes them.
///
/// TrueLayer's token endpoint requires the client secret. That secret must not ship in a
/// production app, so this is a protocol: `DirectTrueLayerTokenExchanger` is for sandbox and
/// personal development only; a production build should use an implementation that calls
/// your own backend, which holds the secret.
public protocol TrueLayerTokenExchanging: Sendable {
    func exchange(code: String) async throws -> OAuthTokens
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens
}

/// Talks to TrueLayer's token endpoint directly with a client secret from the local,
/// git-ignored `Config/Local.xcconfig`. Sandbox / development only.
public struct DirectTrueLayerTokenExchanger: TrueLayerTokenExchanging {
    private let configuration: TrueLayerConfiguration
    private let clientSecret: String
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(configuration: TrueLayerConfiguration, clientSecret: String, http: HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.clientSecret = clientSecret
        self.http = http
        self.now = now
    }

    private var tokenURL: URL {
        configuration.environment.authBaseURL.appendingPathComponent("connect/token")
    }

    public func exchange(code: String) async throws -> OAuthTokens {
        let request = URLRequest.formPost(url: tokenURL, parameters: [
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "client_secret": clientSecret,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code": code,
        ])
        return try await perform(request, previousRefreshToken: nil)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw BankError.reconnectRequired(connectionName: nil)
        }
        let request = URLRequest.formPost(url: tokenURL, parameters: [
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
        ])
        return try await perform(request, previousRefreshToken: refreshToken)
    }

    private func perform(_ request: URLRequest, previousRefreshToken: String?) async throws -> OAuthTokens {
        do {
            let response = try await http.decode(OAuthTokenResponse.self, from: request)
            return response.tokens(now: now(), previousRefreshToken: previousRefreshToken)
        } catch let error as NetworkError {
            if let oauthError = OAuthErrorResponse.parse(error.body) {
                switch oauthError.error {
                case "invalid_grant", "access_denied":
                    throw BankError.reconnectRequired(connectionName: nil)
                case "invalid_client", "unauthorized_client":
                    throw BankError.notConfigured
                default:
                    throw BankError.providerError(oauthError.errorDescription ?? oauthError.error)
                }
            }
            throw BankError.network(error)
        }
    }
}
