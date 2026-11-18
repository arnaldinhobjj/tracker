import Foundation

/// Non-secret metadata about linked banks (names, dates). Tokens live in the Keychain.
public final class BankConnectionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "bank.connections"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [BankConnection] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BankConnection].self, from: data)) ?? []
    }

    public func upsert(_ connection: BankConnection) {
        var connections = all().filter { $0.id != connection.id }
        connections.append(connection)
        save(connections)
    }

    public func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    public func setNeedsReconnect(_ value: Bool, id: String) {
        var connections = all()
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].needsReconnect = value
        save(connections)
    }

    private func save(_ connections: [BankConnection]) {
        lock.lock(); defer { lock.unlock() }
        let sorted = connections.sorted { $0.connectedAt < $1.connectedAt }
        defaults.set(try? JSONEncoder().encode(sorted), forKey: key)
    }
}
