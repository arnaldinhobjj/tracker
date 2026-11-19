import Foundation
import Networking
import SecureStore

/// The outcome of finding the account's sync key on this device.
public enum SyncKeyResolution: Equatable, Sendable {
    case ready(SyncKey)
    /// The account's rows are encrypted with a key this device doesn't have yet (iCloud Keychain
    /// off, or not synced yet). Nothing can be read or written until it arrives, or the user
    /// chooses to start over.
    case missing(keyID: String)
}

/// Finds or creates the key that end-to-end encrypts an account's synced rows.
///
/// Keys live in `store` (in the app: the iCloud-synchronised Keychain), named by user and key id.
/// The server's `sync_keys` table records which key id the account uses, so a second device
/// never invents a competing key: only the first device to register wins, and the others wait
/// for that key to arrive through iCloud Keychain.
public struct SyncKeyManager: Sendable {
    private let store: SecureStoring
    private let generate: @Sendable () -> SyncKey

    public init(store: SecureStoring, generate: @escaping @Sendable () -> SyncKey = { SyncKey.generate() }) {
        self.store = store
        self.generate = generate
    }

    public func localKey(userID: UUID, keyID: String) -> SyncKey? {
        guard let data = try? store.data(for: SecureStoreKey.syncKey(userID: userID, keyID: keyID)),
              let key = SyncKey(data: data), key.id == keyID else { return nil }
        return key
    }

    public func resolve(userID: UUID, rest: SupabaseRESTClient) async throws -> SyncKeyResolution {
        if let record = try await rest.fetchSyncKey() {
            return localKey(userID: userID, keyID: record.keyID).map(SyncKeyResolution.ready) ?? .missing(keyID: record.keyID)
        }

        // No key yet: this is the account's first encrypting device. Save the key before telling
        // the server about it, so a registered id always has a key behind it. (If registering
        // fails the unused key is kept: the request may have reached the server.)
        let key = generate()
        try store.set(key.data, for: SecureStoreKey.syncKey(userID: userID, keyID: key.id))
        try await rest.registerSyncKey(SyncKeyRecord(userID: userID, keyID: key.id))

        guard let winner = try await rest.fetchSyncKey() else { throw NetworkError.invalidResponse }
        if winner.keyID == key.id { return .ready(key) }
        // Another device registered first: ours was never used.
        try? store.remove(SecureStoreKey.syncKey(userID: userID, keyID: key.id))
        return localKey(userID: userID, keyID: winner.keyID).map(SyncKeyResolution.ready) ?? .missing(keyID: winner.keyID)
    }
}
