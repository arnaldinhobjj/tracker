import CryptoKit
import Foundation

/// The symmetric key that end-to-end encrypts a user's synced rows. It is created on the user's
/// first device, kept in iCloud Keychain (so their other devices get it, Apple can't read it) and
/// never sent to the DayLedger backend. The server only learns its `id`, to tell devices which
/// key the account uses.
public struct SyncKey: Sendable, Equatable {
    public static let byteCount = 32

    /// Raw key material (256 bits).
    public let data: Data
    /// Public fingerprint: 32 lowercase hex characters, derived one-way from the key.
    public let id: String

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
        id = Self.fingerprint(of: data)
    }

    public static func generate() -> SyncKey {
        let key = SymmetricKey(size: .bits256)
        return SyncKey(data: key.withUnsafeBytes { Data($0) })!
    }

    static func fingerprint(of data: Data) -> String {
        var input = Data("DayLedger sync key id v1".utf8)
        input.append(data)
        return SHA256.hash(data: input).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: data) }
}

/// An encrypted row body as stored in the `payload` column, with the id of the key that sealed it.
public struct SealedPayload: Codable, Equatable, Sendable {
    public var keyID: String
    /// `v1.` followed by base64 of AES-GCM's combined nonce + ciphertext + tag.
    public var ciphertext: String

    public init(keyID: String, ciphertext: String) {
        self.keyID = keyID
        self.ciphertext = ciphertext
    }
}

public enum SyncCryptoError: Error, Equatable, Sendable {
    /// The row was sealed with a key this device doesn't have.
    case wrongKey(expected: String, found: String)
    /// Not a payload this version understands.
    case malformed
    /// Tampered with, moved to another row or user, or not ours.
    case authenticationFailed
    /// A row without content can't be sealed (programming error).
    case nothingToSeal
}

/// AES-256-GCM for sync rows. The associated data binds each payload to its table, user and row
/// id, so the server (or anyone with database access) can't swap payloads between rows or users
/// without detection.
public enum SyncCipher {
    static let version = "v1."

    public static func seal<T: Encodable>(_ value: T, table: String, userID: UUID, rowID: String, key: SyncKey) throws -> SealedPayload {
        let plaintext = try encoder.encode(value)
        let box = try AES.GCM.seal(plaintext, using: key.symmetricKey, authenticating: associatedData(table, userID, rowID))
        guard let combined = box.combined else { throw SyncCryptoError.malformed }
        return SealedPayload(keyID: key.id, ciphertext: version + combined.base64EncodedString())
    }

    public static func open<T: Decodable>(_ type: T.Type, from sealed: SealedPayload, table: String, userID: UUID, rowID: String,
                                          key: SyncKey) throws -> T {
        guard sealed.keyID == key.id else { throw SyncCryptoError.wrongKey(expected: key.id, found: sealed.keyID) }
        guard sealed.ciphertext.hasPrefix(version),
              let combined = Data(base64Encoded: String(sealed.ciphertext.dropFirst(version.count))),
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw SyncCryptoError.malformed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key.symmetricKey, authenticating: associatedData(table, userID, rowID))
        } catch {
            throw SyncCryptoError.authenticationFailed
        }
        do {
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw SyncCryptoError.malformed
        }
    }

    private static func associatedData(_ table: String, _ userID: UUID, _ rowID: String) -> Data {
        Data("dayledger.sync.v1|\(table)|\(userID.uuidString.lowercased())|\(rowID)".utf8)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
