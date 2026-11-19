import Foundation
import Networking

/// Swaps an authorization code for tokens and refreshes them.
///
/// TrueLayer's token endpoint requires the client secret, which must never ship in the app.
/// Production uses `BackendTrueLayerTokenExchanger`, which calls the `truelayer-token` Edge
/// Function (the secret lives only in its secrets). `DirectTrueLayerTokenExchanger` exists in
/// Debug builds only, for local sandbox work without a backend.
public protocol TrueLayerTokenExchanging: Sendable {
    func exchange(code: String) async throws -> OAuthTokens
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens
}

/// Calls the DayLedger backend (`POST /functions/v1/truelayer-token`), which adds the client
/// secret and forwards to TrueLayer. Works without a DayLedger account: `headers` supplies the
/// project's public anon key.
public struct BackendTrueLayerTokenExchanger: TrueLayerTokenExchanging {
    private let endpoint: URL
    private let headers: @Sendable () async -> [String: String]
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(endpoint: URL, headers: @escaping @Sendable () async -> [String: String], http: HTTPClient = URLSessionHTTPClient(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.endpoint = endpoint
        self.headers = headers
        self.http = http
        self.now = now
    }

    public func exchange(code: String) async throws -> OAuthTokens {
        try await perform(["grant_type": "authorization_code", "code": code], previousRefreshToken: nil)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw BankError.reconnectRequired(connectionName: nil)
        }
        return try await perform(["grant_type": "refresh_token", "refresh_token": refreshToken], previousRefreshToken: refreshToken)
    }

    private func perform(_ body: [String: String], previousRefreshToken: String?) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in await headers() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await TrueLayerTokenResponseHandling.perform(request, http: http, now: now(), previousRefreshToken: previousRefreshToken)
    }
}

/// Used when no backend is configured (and, in Debug, no sandbox secret either): connecting a
/// bank explains that the build isn't set up instead of failing obscurely.
public struct UnavailableTrueLayerTokenExchanger: TrueLayerTokenExchanging {
    public init() {}
    public func exchange(code: String) async throws -> OAuthTokens { throw BankError.notConfigured }
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens { throw BankError.notConfigured }
}

#if DEBUG
/// Talks to TrueLayer's token endpoint directly with a client secret from the local,
/// git-ignored `Config/Local.xcconfig`. **Debug builds only**: this type doesn't exist in Release,
/// and `Config/Release.xcconfig` blanks `TRUELAYER_CLIENT_SECRET`, so no secret can ship.
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
        return try await TrueLayerTokenResponseHandling.perform(request, http: http, now: now(), previousRefreshToken: nil)
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
        return try await TrueLayerTokenResponseHandling.perform(request, http: http, now: now(), previousRefreshToken: refreshToken)
    }
}
#endif

/// Token responses and OAuth errors mean the same thing whether they came from TrueLayer
/// directly or through the backend, which passes TrueLayer's error bodies through.
enum TrueLayerTokenResponseHandling {
    static func perform(_ request: URLRequest, http: HTTPClient, now: Date, previousRefreshToken: String?) async throws -> OAuthTokens {
        do {
            let response = try await http.decode(OAuthTokenResponse.self, from: request)
            return response.tokens(now: now, previousRefreshToken: previousRefreshToken)
        } catch let error as NetworkError {
            if let oauthError = OAuthErrorResponse.parse(error.body) {
                switch oauthError.error {
                case "invalid_grant", "access_denied":
                    throw BankError.reconnectRequired(connectionName: nil)
                case "invalid_client", "unauthorized_client":
                    throw BankError.notConfigured
                case "too_many_requests":
                    throw BankError.rateLimited
                default:
                    // Backend errors use {"error": "<code>"} too; only TrueLayer's are OAuth codes.
                    break
                }
            }
            switch error.statusCode {
            // The function isn't deployed, or the gateway rejected the anon key.
            case 401, 403, 404: throw BankError.notConfigured
            case 429: throw BankError.rateLimited
            default: break
            }
            if let oauthError = OAuthErrorResponse.parse(error.body), let status = error.statusCode, (400..<500).contains(status) {
                throw BankError.providerError(oauthError.errorDescription ?? oauthError.error)
            }
            throw BankError.network(error)
        }
    }
}
