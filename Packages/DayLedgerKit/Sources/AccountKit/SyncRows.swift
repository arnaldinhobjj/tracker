import Foundation

/// A row that can be pulled page by page, ordered by the server's `updated_at`.
public protocol SyncRow: Codable, Sendable {
    /// The server's `updated_at`, exactly as Postgres sent it (kept as text so the cursor never loses precision).
    var updatedAt: String? { get }
    /// The row's id within the user's rows, for tie-breaking rows with the same `updated_at`.
    var cursorID: String? { get }
}

// MARK: - Encrypted rows
//
// Transactions and visits are end-to-end encrypted (docs/backend-contract.md, "Encryption"). On
// the wire a row is `user_id`, `id`, `key_id`, `payload` (the sealed content) and `deleted_at`;
// the legacy plaintext columns are always sent as explicit nulls, which also erases plaintext an
// older app version wrote. Rows written by older versions arrive with plaintext columns and no
// payload: they are still read (`isLegacyPlaintext`) so the app can re-upload them encrypted.

/// What a transaction row holds once decrypted.
public struct TransactionSyncContent: Codable, Equatable, Sendable {
    public var accountID: String
    public var merchant: String
    public var rawDescription: String
    public var amountMinor: Int
    public var currency: String
    /// `debit` or `credit`.
    public var direction: String
    public var bankCategory: String
    /// `SpendCategory` raw value.
    public var category: String
    public var occurredAt: Date
    public var hasTime: Bool
    public var isPending: Bool

    public init(accountID: String, merchant: String, rawDescription: String, amountMinor: Int, currency: String, direction: String,
                bankCategory: String, category: String, occurredAt: Date, hasTime: Bool, isPending: Bool) {
        self.accountID = accountID
        self.merchant = merchant
        self.rawDescription = rawDescription
        self.amountMinor = amountMinor
        self.currency = currency
        self.direction = direction
        self.bankCategory = bankCategory
        self.category = category
        self.occurredAt = occurredAt
        self.hasTime = hasTime
        self.isPending = isPending
    }
}

/// `public.transactions` (contract: docs/backend-contract.md).
public struct TransactionSyncRow: SyncRow, Equatable {
    public static let table = "transactions"

    public var userID: UUID
    public var id: String
    /// The readable content: decrypted, or legacy plaintext. Nil for a pulled encrypted row that
    /// hasn't been opened yet.
    public var content: TransactionSyncContent?
    /// The encrypted content as stored on the server. Nil for legacy plaintext rows.
    public var sealed: SealedPayload?
    /// Set by the server trigger; never sent.
    public var updatedAt: String?
    public var deletedAt: Date?

    public init(userID: UUID, id: String, content: TransactionSyncContent?, sealed: SealedPayload? = nil,
                updatedAt: String? = nil, deletedAt: Date? = nil) {
        self.userID = userID
        self.id = id
        self.content = content
        self.sealed = sealed
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// A row written by an app version without encryption: its content is readable by the server
    /// and it should be re-uploaded encrypted.
    public var isLegacyPlaintext: Bool { sealed == nil && content != nil }

    public var cursorID: String? { id }

    /// A copy with `content` encrypted into `sealed`, ready to upload.
    public func sealing(with key: SyncKey) throws -> TransactionSyncRow {
        guard let content else { throw SyncCryptoError.nothingToSeal }
        var copy = self
        copy.sealed = try SyncCipher.seal(content, table: Self.table, userID: userID, rowID: id, key: key)
        return copy
    }

    /// A copy with `sealed` decrypted into `content`. Legacy plaintext rows are returned as they are.
    public func opening(with key: SyncKey) throws -> TransactionSyncRow {
        guard let sealed else { return self }
        var copy = self
        copy.content = try SyncCipher.open(TransactionSyncContent.self, from: sealed, table: Self.table, userID: userID, rowID: id, key: key)
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id
        case keyID = "key_id"
        case payload
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        // Legacy plaintext columns: read from old rows, always written as null.
        case accountID = "account_id"
        case merchant
        case rawDescription = "raw_description"
        case amountMinor = "amount_minor"
        case currency
        case direction
        case bankCategory = "bank_category"
        case category
        case occurredAt = "occurred_at"
        case hasTime = "has_time"
        case isPending = "is_pending"
    }

    static let legacyColumns: [CodingKeys] = [.accountID, .merchant, .rawDescription, .amountMinor, .currency, .direction,
                                             .bankCategory, .category, .occurredAt, .hasTime, .isPending]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeISODateIfPresent(forKey: .deletedAt)
        if let payload = try c.decodeIfPresent(String.self, forKey: .payload) {
            sealed = SealedPayload(keyID: try c.decodeIfPresent(String.self, forKey: .keyID) ?? "", ciphertext: payload)
            content = nil
        } else if try c.decodeIfPresent(String.self, forKey: .occurredAt) != nil {
            sealed = nil
            content = TransactionSyncContent(
                accountID: try c.decodeIfPresent(String.self, forKey: .accountID) ?? "",
                merchant: try c.decodeIfPresent(String.self, forKey: .merchant) ?? "",
                rawDescription: try c.decodeIfPresent(String.self, forKey: .rawDescription) ?? "",
                amountMinor: try c.decodeFlexibleInt(forKey: .amountMinor),
                currency: (try c.decodeIfPresent(String.self, forKey: .currency) ?? "GBP").trimmingCharacters(in: .whitespaces),
                direction: try c.decodeIfPresent(String.self, forKey: .direction) ?? "debit",
                bankCategory: try c.decodeIfPresent(String.self, forKey: .bankCategory) ?? "",
                category: try c.decodeIfPresent(String.self, forKey: .category) ?? "other",
                occurredAt: try c.decodeISODate(forKey: .occurredAt),
                hasTime: try c.decodeIfPresent(Bool.self, forKey: .hasTime) ?? false,
                isPending: try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
            )
        } else {
            sealed = nil
            content = nil
        }
    }

    /// Only sealed rows can be encoded: uploading plaintext is impossible by construction. Every
    /// column is always written (nulls included), because PostgREST bulk upserts need identical
    /// keys in every object. `updated_at` is never sent; the server trigger owns it.
    public func encode(to encoder: Encoder) throws {
        guard let sealed else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "Refusing to upload an unencrypted transaction row."))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(id, forKey: .id)
        try c.encode(sealed.keyID, forKey: .keyID)
        try c.encode(sealed.ciphertext, forKey: .payload)
        try c.encode(deletedAt.map(ISO8601.string(from:)), forKey: .deletedAt)
        for column in Self.legacyColumns {
            try c.encodeNil(forKey: column)
        }
    }
}

/// What a visit row holds once decrypted. Calendar bookkeeping is deliberately absent: it
/// describes this device's Google calendar and never leaves the device.
public struct VisitSyncContent: Codable, Equatable, Sendable {
    public var arrival: Date
    public var departure: Date?
    public var latitude: Double
    public var longitude: Double
    public var placeName: String?
    public var placeCategory: String?
    public var isNamedPlace: Bool
    public var isResolved: Bool

    public init(arrival: Date, departure: Date?, latitude: Double, longitude: Double, placeName: String?, placeCategory: String?,
                isNamedPlace: Bool, isResolved: Bool) {
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.placeCategory = placeCategory
        self.isNamedPlace = isNamedPlace
        self.isResolved = isResolved
    }
}

/// `public.visits`. Only uploaded when the user turns on visit sync.
public struct VisitSyncRow: SyncRow, Equatable {
    public static let table = "visits"

    public var userID: UUID
    public var id: String
    public var content: VisitSyncContent?
    public var sealed: SealedPayload?
    public var updatedAt: String?
    public var deletedAt: Date?

    public init(userID: UUID, id: String, content: VisitSyncContent?, sealed: SealedPayload? = nil,
                updatedAt: String? = nil, deletedAt: Date? = nil) {
        self.userID = userID
        self.id = id
        self.content = content
        self.sealed = sealed
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isLegacyPlaintext: Bool { sealed == nil && content != nil }

    public var cursorID: String? { id }

    public func sealing(with key: SyncKey) throws -> VisitSyncRow {
        guard let content else { throw SyncCryptoError.nothingToSeal }
        var copy = self
        copy.sealed = try SyncCipher.seal(content, table: Self.table, userID: userID, rowID: id, key: key)
        return copy
    }

    public func opening(with key: SyncKey) throws -> VisitSyncRow {
        guard let sealed else { return self }
        var copy = self
        copy.content = try SyncCipher.open(VisitSyncContent.self, from: sealed, table: Self.table, userID: userID, rowID: id, key: key)
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id
        case keyID = "key_id"
        case payload
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        // Legacy plaintext columns.
        case arrival
        case departure
        case latitude
        case longitude
        case placeName = "place_name"
        case placeCategory = "place_category"
        case isNamedPlace = "is_named_place"
        case isResolved = "is_resolved"
        case calendarEventID = "calendar_event_id"
        case calendarContentHash = "calendar_content_hash"
        case calendarSyncedAt = "calendar_synced_at"
    }

    static let legacyColumns: [CodingKeys] = [.arrival, .departure, .latitude, .longitude, .placeName, .placeCategory, .isNamedPlace,
                                             .isResolved, .calendarEventID, .calendarContentHash, .calendarSyncedAt]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeISODateIfPresent(forKey: .deletedAt)
        if let payload = try c.decodeIfPresent(String.self, forKey: .payload) {
            sealed = SealedPayload(keyID: try c.decodeIfPresent(String.self, forKey: .keyID) ?? "", ciphertext: payload)
            content = nil
        } else if let latitude = try c.decodeIfPresent(Double.self, forKey: .latitude),
                  let longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) {
            sealed = nil
            content = VisitSyncContent(
                arrival: try c.decodeISODate(forKey: .arrival),
                departure: try c.decodeISODateIfPresent(forKey: .departure),
                latitude: latitude,
                longitude: longitude,
                placeName: try c.decodeIfPresent(String.self, forKey: .placeName),
                placeCategory: try c.decodeIfPresent(String.self, forKey: .placeCategory),
                isNamedPlace: try c.decodeIfPresent(Bool.self, forKey: .isNamedPlace) ?? false,
                isResolved: try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
            )
        } else {
            sealed = nil
            content = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard let sealed else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "Refusing to upload an unencrypted visit row."))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(id, forKey: .id)
        try c.encode(sealed.keyID, forKey: .keyID)
        try c.encode(sealed.ciphertext, forKey: .payload)
        try c.encode(deletedAt.map(ISO8601.string(from:)), forKey: .deletedAt)
        for column in Self.legacyColumns {
            try c.encodeNil(forKey: column)
        }
    }
}

/// `public.sync_keys`: which key the account's rows are encrypted with (its id only; the key
/// itself never leaves the user's devices and iCloud Keychain).
public struct SyncKeyRecord: Codable, Equatable, Sendable {
    public var userID: UUID
    public var keyID: String

    public init(userID: UUID, keyID: String) {
        self.userID = userID
        self.keyID = keyID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case keyID = "key_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        keyID = try c.decode(String.self, forKey: .keyID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(keyID, forKey: .keyID)
    }
}

/// The `settings` jsonb of `public.user_settings`.
public struct SyncedSettings: Codable, Equatable, Sendable {
    public var locationLogging: Bool
    public var calendarWriting: Bool
    public var onlyNamedPlaces: Bool
    public var minimumVisitMinutes: Int
    public var aiAssistant: Bool
    /// Upload visits (encrypted) to the account. Account-wide, off unless the user turns it on.
    /// Settings written by older app versions lack this key, which reads as off.
    public var visitSync: Bool

    public init(locationLogging: Bool, calendarWriting: Bool, onlyNamedPlaces: Bool, minimumVisitMinutes: Int, aiAssistant: Bool,
                visitSync: Bool = false) {
        self.locationLogging = locationLogging
        self.calendarWriting = calendarWriting
        self.onlyNamedPlaces = onlyNamedPlaces
        self.minimumVisitMinutes = minimumVisitMinutes
        self.aiAssistant = aiAssistant
        self.visitSync = visitSync
    }

    /// Missing keys (written by an older or newer app) fall back to the app's defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationLogging = try c.decodeIfPresent(Bool.self, forKey: .locationLogging) ?? false
        calendarWriting = try c.decodeIfPresent(Bool.self, forKey: .calendarWriting) ?? false
        onlyNamedPlaces = try c.decodeIfPresent(Bool.self, forKey: .onlyNamedPlaces) ?? true
        minimumVisitMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumVisitMinutes) ?? 5
        aiAssistant = try c.decodeIfPresent(Bool.self, forKey: .aiAssistant) ?? false
        visitSync = try c.decodeIfPresent(Bool.self, forKey: .visitSync) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case locationLogging, calendarWriting, onlyNamedPlaces, minimumVisitMinutes, aiAssistant, visitSync
    }
}

/// `public.user_settings` (primary key `user_id`, one row per user).
public struct UserSettingsSyncRow: SyncRow, Equatable {
    public var userID: UUID
    public var settings: SyncedSettings
    public var updatedAt: String?

    public init(userID: UUID, settings: SyncedSettings, updatedAt: String? = nil) {
        self.userID = userID
        self.settings = settings
        self.updatedAt = updatedAt
    }

    public var cursorID: String? { nil }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case settings
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        settings = try c.decode(SyncedSettings.self, forKey: .settings)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(settings, forKey: .settings)
    }
}

extension KeyedDecodingContainer {
    func decodeISODate(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let date = ISO8601.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an ISO 8601 date: \(raw)")
        }
        return date
    }

    func decodeISODateIfPresent(forKey key: Key) throws -> Date? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = ISO8601.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an ISO 8601 date: \(raw)")
        }
        return date
    }

    /// `bigint` can arrive as a JSON number or, from some PostgREST settings, as a string.
    func decodeFlexibleInt(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        let raw = try decode(String.self, forKey: key)
        guard let value = Int(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an integer: \(raw)")
        }
        return value
    }
}
