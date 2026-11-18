import Foundation

/// Storage for secrets (OAuth tokens, API keys). Production code uses `KeychainStore`.
public protocol SecureStoring: AnyObject, Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
    /// Removes every item this store owns.
    func removeAll() throws
}

public extension SecureStoring {
    func string(for key: String) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }

    func value<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        guard let data = try data(for: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func setValue<T: Encodable>(_ value: T, for key: String) throws {
        try set(JSONEncoder().encode(value), for: key)
    }
}

/// Key names used across modules, kept in one place so "delete all my data" can find them.
public enum SecureStoreKey {
    public static func trueLayerTokens(connectionID: String) -> String { "truelayer.tokens.\(connectionID)" }
    public static let googleTokens = "google.tokens"
    public static func aiAPIKey(provider: String) -> String { "ai.apikey.\(provider)" }
}

/// In-memory store for tests, previews and UI tests.
public final class InMemorySecureStore: SecureStoring, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func set(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = data
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
