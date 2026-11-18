import Foundation
import Networking
import SecureStore
import SharedModels

/// Holds one connection's tokens, refreshing them when needed. An actor so that concurrent
/// requests share a single refresh instead of racing (TrueLayer rotates refresh tokens).
actor TrueLayerTokenProvider {
    private let connectionID: String
    private let store: SecureStoring
    private let exchanger: TrueLayerTokenExchanging
    private var refreshTask: Task<OAuthTokens, Error>?

    init(connectionID: String, store: SecureStoring, exchanger: TrueLayerTokenExchanging) {
        self.connectionID = connectionID
        self.store = store
        self.exchanger = exchanger
    }

    private var key: String { SecureStoreKey.trueLayerTokens(connectionID: connectionID) }

    func accessToken() async throws -> String {
        guard let tokens = try store.value(OAuthTokens.self, for: key) else {
            throw BankError.notConnected
        }
        if tokens.isExpired() {
            return try await refresh(tokens).accessToken
        }
        return tokens.accessToken
    }

    /// Forces a refresh, e.g. after a 401.
    func refreshNow() async throws -> String {
        guard let tokens = try store.value(OAuthTokens.self, for: key) else {
            throw BankError.notConnected
        }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await exchanger.refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await task.value
        try store.setValue(fresh, for: key)
        return fresh
    }
}

/// Typed calls to the TrueLayer Data API for one connection.
struct TrueLayerDataClient {
    enum AccountKind { case account, card }

    let environment: TrueLayerEnvironment
    let http: HTTPClient
    let tokens: TrueLayerTokenProvider

    func me() async throws -> TLMe? {
        try await get(TLResults<TLMe>.self, path: "/data/v1/me").results.first
    }

    func accounts() async throws -> [TLAccount] {
        try await get(TLResults<TLAccount>.self, path: "/data/v1/accounts").results
    }

    /// Not every bank supports cards; those return 501/404, which we treat as "no cards".
    func cards() async throws -> [TLCard] {
        do {
            return try await get(TLResults<TLCard>.self, path: "/data/v1/cards").results
        } catch BankError.network(let error) where [400, 404, 501].contains(error.statusCode ?? 0) {
            return []
        }
    }

    func transactions(accountID: String, kind: AccountKind, from: Date, to: Date, pending: Bool) async throws -> [TLTransaction] {
        let base = kind == .account ? "/data/v1/accounts" : "/data/v1/cards"
        var path = "\(base)/\(accountID)/transactions"
        if pending { path += "/pending" }
        let query = pending ? [] : [
            URLQueryItem(name: "from", value: TrueLayerDateParser.queryString(from)),
            URLQueryItem(name: "to", value: TrueLayerDateParser.queryString(to)),
        ]
        do {
            return try await get(TLResults<TLTransaction>.self, path: path, query: query).results
        } catch BankError.network(let error) where pending && [400, 404, 501].contains(error.statusCode ?? 0) {
            // Some banks don't expose pending transactions.
            return []
        }
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: environment.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        request.setBearer(try await tokens.accessToken())
        do {
            return try await http.decode(T.self, from: request, decoder: .trueLayer)
        } catch NetworkError.unauthorized {
            // Access token rejected early (revoked or clock skew): refresh once and retry.
            request.setBearer(try await tokens.refreshNow())
            do {
                return try await http.decode(T.self, from: request, decoder: .trueLayer)
            } catch let error as NetworkError {
                throw Self.map(error)
            }
        } catch let error as NetworkError {
            throw Self.map(error)
        }
    }

    static func map(_ error: NetworkError) -> BankError {
        switch error {
        case .unauthorized, .forbidden:
            // 403 covers "sca_exceeded" / expired consent: the user must re-authorise with the bank.
            return .reconnectRequired(connectionName: nil)
        case .http(429, _):
            return .rateLimited
        default:
            return .network(error)
        }
    }
}
