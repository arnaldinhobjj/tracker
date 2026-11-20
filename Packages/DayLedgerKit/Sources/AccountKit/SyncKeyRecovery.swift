import CryptoKit
import Foundation

/// A recovery key: 256 random bits the user keeps (written down, or in a password manager) to
/// restore their end-to-end sync key on a device without iCloud Keychain.
///
/// Shown as 55 characters in groups of five, in Crockford's base32 (digits and capitals, no I, L,
/// O or U, so it is hard to misread). The last characters are a checksum: a typo is reported as a
/// typo, not as the wrong key.
public struct RecoveryKey: Sendable, Equatable {
    public static let secretByteCount = 32
    static let checksumByteCount = 2
    static let groupLength = 5
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The secret (256 bits). Never leaves the device; only a key derived from it is used.
    let secret: Data

    public enum ParseError: Error, Equatable, Sendable {
        /// Too short or too long.
        case wrongLength
        /// A character that can't be part of a recovery key.
        case invalidCharacter(Character)
        /// Every character is valid but the checksum doesn't match: a typo.
        case checksumMismatch
    }

    init?(secret: Data) {
        guard secret.count == Self.secretByteCount else { return nil }
        self.secret = secret
    }

    public static func generate() -> RecoveryKey {
        let key = SymmetricKey(size: .bits256)
        return RecoveryKey(secret: key.withUnsafeBytes { Data($0) })!
    }

    /// e.g. "7K2QF-W9D3M-…", 11 groups of five.
    public var formatted: String {
        let characters = Self.encode(secret + Self.checksum(of: secret))
        return stride(from: 0, to: characters.count, by: Self.groupLength)
            .map { String(characters[$0..<min($0 + Self.groupLength, characters.count)]) }
            .joined(separator: "-")
    }

    /// Reads a key as typed or pasted: case, spaces and dashes don't matter, and O, I and L are
    /// read as 0, 1 and 1.
    public static func parse(_ text: String) throws -> RecoveryKey {
        var normalised: [Character] = []
        for character in text.uppercased() {
            switch character {
            case " ", "-", "\n", "\t": continue
            case "O": normalised.append("0")
            case "I", "L": normalised.append("1")
            default:
                guard alphabet.contains(character) else { throw ParseError.invalidCharacter(character) }
                normalised.append(character)
            }
        }
        let byteCount = secretByteCount + checksumByteCount
        guard normalised.count == encodedLength(byteCount: byteCount),
              let bytes = decode(normalised, byteCount: byteCount) else {
            throw ParseError.wrongLength
        }
        let secret = bytes.prefix(secretByteCount)
        guard bytes.suffix(checksumByteCount) == checksum(of: secret) else { throw ParseError.checksumMismatch }
        return RecoveryKey(secret: Data(secret))!
    }

    static func checksum(of secret: Data) -> Data {
        var input = Data("DayLedger recovery key v1".utf8)
        input.append(secret)
        return Data(SHA256.hash(data: input).prefix(checksumByteCount))
    }

    // MARK: Base32 (Crockford alphabet, no padding)

    static func encodedLength(byteCount: Int) -> Int {
        (byteCount * 8 + 4) / 5
    }

    static func encode(_ data: Data) -> [Character] {
        var characters: [Character] = []
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                characters.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            characters.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return characters
    }

    /// Nil when the padding bits aren't zero (not a key this app produced).
    static func decode(_ characters: [Character], byteCount: Int) -> Data? {
        var bytes = Data()
        var buffer = 0
        var bits = 0
        for character in characters {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        guard bytes.count == byteCount, buffer == 0 else { return nil }
        return bytes
    }
}

public enum SyncKeyRecoveryError: Error, Equatable, Sendable {
    /// The account has no recovery copy of its current key.
    case notSetUp
    /// The recovery key is valid but isn't the one that made this copy.
    case wrongRecoveryKey
    /// The account has no sync key yet (nothing to recover).
    case noKey
}

/// Wraps the sync key with a key derived from the recovery key (HKDF-SHA256), using AES-256-GCM.
/// The associated data binds the copy to the user and the key's id, so a copy can't be moved to
/// another account or swapped for another key without detection.
public enum SyncKeyRecovery {
    static let version = "v1."
    static let label = "dayledger.recovery.v1"

    public static func wrap(_ key: SyncKey, with recovery: RecoveryKey, userID: UUID) throws -> String {
        let box = try AES.GCM.seal(key.data, using: wrappingKey(recovery, userID: userID),
                                   authenticating: associatedData(userID: userID, keyID: key.id))
        guard let combined = box.combined else { throw SyncCryptoError.malformed }
        return version + combined.base64EncodedString()
    }

    public static func unwrap(_ wrapped: String, keyID: String, with recovery: RecoveryKey, userID: UUID) throws -> SyncKey {
        guard wrapped.hasPrefix(version),
              let combined = Data(base64Encoded: String(wrapped.dropFirst(version.count))),
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw SyncCryptoError.malformed
        }
        let data: Data
        do {
            data = try AES.GCM.open(box, using: wrappingKey(recovery, userID: userID),
                                    authenticating: associatedData(userID: userID, keyID: keyID))
        } catch {
            throw SyncKeyRecoveryError.wrongRecoveryKey
        }
        guard let key = SyncKey(data: data), key.id == keyID else { throw SyncCryptoError.malformed }
        return key
    }

    private static func wrappingKey(_ recovery: RecoveryKey, userID: UUID) -> SymmetricKey {
        // The recovery key is 256 random bits, so a fast KDF is enough (no password stretching).
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recovery.secret),
                               salt: Data(label.utf8),
                               info: Data("\(label)|\(userID.uuidString.lowercased())".utf8),
                               outputByteCount: 32)
    }

    private static func associatedData(userID: UUID, keyID: String) -> Data {
        Data("\(label)|\(userID.uuidString.lowercased())|\(keyID)".utf8)
    }
}

/// `public.sync_key_recovery`: the sync key wrapped with the user's recovery key.
public struct SyncKeyRecoveryRecord: Codable, Equatable, Sendable {
    public var userID: UUID
    public var keyID: String
    public var wrappedKey: String

    public init(userID: UUID, keyID: String, wrappedKey: String) {
        self.userID = userID
        self.keyID = keyID
        self.wrappedKey = wrappedKey
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case keyID = "key_id"
        case wrappedKey = "wrapped_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        keyID = try c.decode(String.self, forKey: .keyID)
        wrappedKey = try c.decode(String.self, forKey: .wrappedKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(keyID, forKey: .keyID)
        try c.encode(wrappedKey, forKey: .wrappedKey)
    }
}
