import Foundation
import Networking
import SecureStore
import SharedModels

/// `BankService` backed by TrueLayer's Data API.
public final class TrueLayerBankService: BankService, @unchecked Sendable {
    private let configuration: TrueLayerConfiguration
    private let exchanger: TrueLayerTokenExchanging
    private let secureStore: SecureStoring
    private let connectionStore: BankConnectionStore
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var providers: [String: TrueLayerTokenProvider] = [:]

    public init(
        configuration: TrueLayerConfiguration,
        exchanger: TrueLayerTokenExchanging,
        secureStore: SecureStoring,
        connectionStore: BankConnectionStore,
        http: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.exchanger = exchanger
        self.secureStore = secureStore
        self.connectionStore = connectionStore
        self.http = http
        self.now = now
    }

    public var isConfigured: Bool { configuration.isConfigured }

    public func connections() -> [BankConnection] {
        connectionStore.all()
    }

    public func makeAuthorizationRequest() throws -> BankAuthorizationRequest {
        guard isConfigured else { throw BankError.notConfigured }
        let state = OAuthCallback.randomURLSafeString(length: 32)
        return BankAuthorizationRequest(
            url: configuration.authorizationURL(state: state),
            callbackURLScheme: configuration.callbackURLScheme,
            state: state
        )
    }

    public func completeAuthorization(callbackURL: URL, request: BankAuthorizationRequest) async throws -> BankConnection {
        let code = try configuration.authorizationCode(from: callbackURL, expectedState: request.state)
        let tokens = try await exchanger.exchange(code: code)
        let connectionID = UUID().uuidString
        try secureStore.setValue(tokens, for: SecureStoreKey.trueLayerTokens(connectionID: connectionID))

        let client = dataClient(for: connectionID)
        let me = try? await client.me()
        let connection = BankConnection(
            id: connectionID,
            providerName: me?.provider?.displayName ?? "Bank",
            providerID: me?.provider?.providerId,
            connectedAt: now()
        )

        // Reconnecting the same bank replaces the old connection rather than duplicating it.
        if let providerID = connection.providerID {
            for old in connectionStore.all() where old.providerID == providerID {
                try? secureStore.remove(SecureStoreKey.trueLayerTokens(connectionID: old.id))
                connectionStore.remove(id: old.id)
            }
        }
        connectionStore.upsert(connection)
        return connection
    }

    public func fetchTransactions(since: Date, until: Date) async -> BankFetchResult {
        var result = BankFetchResult()
        for connection in connectionStore.all() {
            do {
                let fetched = try await fetch(connection: connection, since: since, until: until)
                result.transactions += fetched.transactions
                result.refreshedAccountIDs.formUnion(fetched.accountIDs)
                if connection.needsReconnect {
                    connectionStore.setNeedsReconnect(false, id: connection.id)
                }
            } catch let error as BankError {
                var failed = connection
                if case .reconnectRequired = error {
                    connectionStore.setNeedsReconnect(true, id: connection.id)
                    failed.needsReconnect = true
                }
                result.failures.append(BankConnectionFailure(connection: failed, error: Self.named(error, connection)))
            } catch {
                result.failures.append(BankConnectionFailure(connection: connection, error: .providerError(String(describing: error))))
            }
        }
        return result
    }

    private func fetch(connection: BankConnection, since: Date, until: Date) async throws -> (transactions: [BankTransaction], accountIDs: Set<String>) {
        let client = dataClient(for: connection.id)
        var transactions: [BankTransaction] = []
        var accountIDs: Set<String> = []

        let accounts = try await client.accounts().map { ($0.accountId, TrueLayerDataClient.AccountKind.account) }
        let cards = try await client.cards().map { ($0.accountId, TrueLayerDataClient.AccountKind.card) }

        for (accountID, kind) in accounts + cards {
            let settled = try await client.transactions(accountID: accountID, kind: kind, from: since, to: until, pending: false)
            let pending = try await client.transactions(accountID: accountID, kind: kind, from: since, to: until, pending: true)
            transactions += settled.compactMap { TransactionMapper.map($0, accountID: accountID, isPending: false) }
            transactions += pending.compactMap { TransactionMapper.map($0, accountID: accountID, isPending: true) }
            accountIDs.insert(accountID)
        }
        return (transactions, accountIDs)
    }

    public func disconnect(connectionID: String) async {
        let key = SecureStoreKey.trueLayerTokens(connectionID: connectionID)
        // Ask TrueLayer to delete the stored consent. Best effort: local data is removed regardless.
        if let tokens = try? secureStore.value(OAuthTokens.self, for: key) {
            var request = URLRequest(url: configuration.environment.authBaseURL.appendingPathComponent("api/delete"))
            request.httpMethod = "DELETE"
            request.setBearer(tokens.accessToken)
            _ = try? await http.send(request)
        }
        try? secureStore.remove(key)
        connectionStore.remove(id: connectionID)
        lock.withLock { providers[connectionID] = nil }
    }

    public func disconnectAll() async {
        for connection in connectionStore.all() {
            await disconnect(connectionID: connection.id)
        }
        connectionStore.removeAll()
    }

    private func dataClient(for connectionID: String) -> TrueLayerDataClient {
        let provider = lock.withLock {
            let provider = providers[connectionID] ?? TrueLayerTokenProvider(connectionID: connectionID, store: secureStore, exchanger: exchanger)
            providers[connectionID] = provider
            return provider
        }
        return TrueLayerDataClient(environment: configuration.environment, http: http, tokens: provider)
    }

    private static func named(_ error: BankError, _ connection: BankConnection) -> BankError {
        if case .reconnectRequired = error { return .reconnectRequired(connectionName: connection.providerName) }
        return error
    }
}
