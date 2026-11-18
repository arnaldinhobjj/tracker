import Foundation
import Networking
import SharedModels

/// A linked bank (one OAuth consent). A connection can expose several accounts and cards.
public struct BankConnection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var providerName: String
    public var providerID: String?
    public var connectedAt: Date
    /// Set when the consent expired or was revoked; the user must reconnect.
    public var needsReconnect: Bool

    public init(id: String, providerName: String, providerID: String? = nil, connectedAt: Date, needsReconnect: Bool = false) {
        self.id = id
        self.providerName = providerName
        self.providerID = providerID
        self.connectedAt = connectedAt
        self.needsReconnect = needsReconnect
    }
}

public enum BankError: Error, Equatable, Sendable {
    /// Client ID (or sandbox secret) missing from `Config/Local.xcconfig`.
    case notConfigured
    case notConnected
    case authorizationCancelled
    case authorizationDenied(String)
    case stateMismatch
    /// The consent expired (UK banks require re-confirmation every 90 days) or the refresh token was revoked.
    case reconnectRequired(connectionName: String?)
    case rateLimited
    case network(NetworkError)
    case providerError(String)
}

/// What the app needs to open the bank's login page.
public struct BankAuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let callbackURLScheme: String
    public let state: String

    public init(url: URL, callbackURLScheme: String, state: String) {
        self.url = url
        self.callbackURLScheme = callbackURLScheme
        self.state = state
    }
}

public struct BankConnectionFailure: Sendable, Equatable {
    public let connection: BankConnection
    public let error: BankError

    public init(connection: BankConnection, error: BankError) {
        self.connection = connection
        self.error = error
    }
}

public struct BankFetchResult: Sendable {
    public var transactions: [BankTransaction]
    /// Accounts that were fetched successfully. Cached pending transactions for these
    /// accounts should be replaced (pending items disappear when they settle).
    public var refreshedAccountIDs: Set<String>
    public var failures: [BankConnectionFailure]

    public init(transactions: [BankTransaction] = [], refreshedAccountIDs: Set<String> = [], failures: [BankConnectionFailure] = []) {
        self.transactions = transactions
        self.refreshedAccountIDs = refreshedAccountIDs
        self.failures = failures
    }
}

/// The app talks to banks only through this protocol, so the aggregator can be swapped.
public protocol BankService: Sendable {
    var isConfigured: Bool { get }
    func connections() -> [BankConnection]
    func makeAuthorizationRequest() throws -> BankAuthorizationRequest
    func completeAuthorization(callbackURL: URL, request: BankAuthorizationRequest) async throws -> BankConnection
    func fetchTransactions(since: Date, until: Date) async -> BankFetchResult
    /// Revokes the consent with the aggregator (best effort) and deletes local tokens.
    func disconnect(connectionID: String) async
    func disconnectAll() async
}
