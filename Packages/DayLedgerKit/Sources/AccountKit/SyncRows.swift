import Foundation

/// A row that can be pulled page by page, ordered by the server's `updated_at`.
public protocol SyncRow: Codable, Sendable {
    /// The server's `updated_at`, exactly as Postgres sent it (kept as text so the cursor never loses precision).
    var updatedAt: String? { get }
    /// The row's id within the user's rows, for tie-breaking rows with the same `updated_at`.
    var cursorID: String? { get }
}

/// `public.transactions` (contract: docs/backend-contract.md). Columns are snake_case on the wire.
public struct TransactionRow: SyncRow, Equatable {
    public var userID: UUID
    public var id: String
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
    /// Set by the server trigger; never sent.
    public var updatedAt: String?
    public var deletedAt: Date?

    public init(userID: UUID, id: String, accountID: String, merchant: String, rawDescription: String, amountMinor: Int,
                currency: String, direction: String, bankCategory: String, category: String, occurredAt: Date,
                hasTime: Bool, isPending: Bool, updatedAt: String? = nil, deletedAt: Date? = nil) {
        self.userID = userID
        self.id = id
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
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var cursorID: String? { id }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id
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
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        id = try c.decode(String.self, forKey: .id)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant) ?? ""
        rawDescription = try c.decodeIfPresent(String.self, forKey: .rawDescription) ?? ""
        amountMinor = try c.decodeFlexibleInt(forKey: .amountMinor)
        currency = (try c.decodeIfPresent(String.self, forKey: .currency) ?? "GBP").trimmingCharacters(in: .whitespaces)
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? "debit"
        bankCategory = try c.decodeIfPresent(String.self, forKey: .bankCategory) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        occurredAt = try c.decodeISODate(forKey: .occurredAt)
        hasTime = try c.decodeIfPresent(Bool.self, forKey: .hasTime) ?? false
        isPending = try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeISODateIfPresent(forKey: .deletedAt)
    }

    /// Every column is always written (nulls included): PostgREST bulk upserts need identical keys
    /// in every object. `updated_at` is never sent; the server trigger owns it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(id, forKey: .id)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(merchant, forKey: .merchant)
        try c.encode(rawDescription, forKey: .rawDescription)
        try c.encode(amountMinor, forKey: .amountMinor)
        try c.encode(currency, forKey: .currency)
        try c.encode(direction, forKey: .direction)
        try c.encode(bankCategory, forKey: .bankCategory)
        try c.encode(category, forKey: .category)
        try c.encode(ISO8601.string(from: occurredAt), forKey: .occurredAt)
        try c.encode(hasTime, forKey: .hasTime)
        try c.encode(isPending, forKey: .isPending)
        try c.encode(deletedAt.map(ISO8601.string(from:)), forKey: .deletedAt)
    }
}

/// `public.visits`.
public struct VisitRow: SyncRow, Equatable {
    public var userID: UUID
    public var id: String
    public var arrival: Date
    public var departure: Date?
    public var latitude: Double
    public var longitude: Double
    public var placeName: String?
    public var placeCategory: String?
    public var isNamedPlace: Bool
    public var isResolved: Bool
    public var calendarEventID: String?
    public var calendarContentHash: String?
    public var calendarSyncedAt: Date?
    public var updatedAt: String?
    public var deletedAt: Date?

    public init(userID: UUID, id: String, arrival: Date, departure: Date?, latitude: Double, longitude: Double,
                placeName: String?, placeCategory: String?, isNamedPlace: Bool, isResolved: Bool,
                calendarEventID: String?, calendarContentHash: String?, calendarSyncedAt: Date?,
                updatedAt: String? = nil, deletedAt: Date? = nil) {
        self.userID = userID
        self.id = id
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.placeCategory = placeCategory
        self.isNamedPlace = isNamedPlace
        self.isResolved = isResolved
        self.calendarEventID = calendarEventID
        self.calendarContentHash = calendarContentHash
        self.calendarSyncedAt = calendarSyncedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var cursorID: String? { id }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id
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
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        id = try c.decode(String.self, forKey: .id)
        arrival = try c.decodeISODate(forKey: .arrival)
        departure = try c.decodeISODateIfPresent(forKey: .departure)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        placeCategory = try c.decodeIfPresent(String.self, forKey: .placeCategory)
        isNamedPlace = try c.decodeIfPresent(Bool.self, forKey: .isNamedPlace) ?? false
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarContentHash = try c.decodeIfPresent(String.self, forKey: .calendarContentHash)
        calendarSyncedAt = try c.decodeISODateIfPresent(forKey: .calendarSyncedAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeISODateIfPresent(forKey: .deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID.uuidString.lowercased(), forKey: .userID)
        try c.encode(id, forKey: .id)
        try c.encode(ISO8601.string(from: arrival), forKey: .arrival)
        try c.encode(departure.map(ISO8601.string(from:)), forKey: .departure)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(placeName, forKey: .placeName)
        try c.encode(placeCategory, forKey: .placeCategory)
        try c.encode(isNamedPlace, forKey: .isNamedPlace)
        try c.encode(isResolved, forKey: .isResolved)
        try c.encode(calendarEventID, forKey: .calendarEventID)
        try c.encode(calendarContentHash, forKey: .calendarContentHash)
        try c.encode(calendarSyncedAt.map(ISO8601.string(from:)), forKey: .calendarSyncedAt)
        try c.encode(deletedAt.map(ISO8601.string(from:)), forKey: .deletedAt)
    }
}

/// The `settings` jsonb of `public.user_settings`.
public struct SyncedSettings: Codable, Equatable, Sendable {
    public var locationLogging: Bool
    public var calendarWriting: Bool
    public var onlyNamedPlaces: Bool
    public var minimumVisitMinutes: Int
    public var aiAssistant: Bool

    public init(locationLogging: Bool, calendarWriting: Bool, onlyNamedPlaces: Bool, minimumVisitMinutes: Int, aiAssistant: Bool) {
        self.locationLogging = locationLogging
        self.calendarWriting = calendarWriting
        self.onlyNamedPlaces = onlyNamedPlaces
        self.minimumVisitMinutes = minimumVisitMinutes
        self.aiAssistant = aiAssistant
    }

    /// Missing keys (written by an older or newer app) fall back to the app's defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationLogging = try c.decodeIfPresent(Bool.self, forKey: .locationLogging) ?? false
        calendarWriting = try c.decodeIfPresent(Bool.self, forKey: .calendarWriting) ?? false
        onlyNamedPlaces = try c.decodeIfPresent(Bool.self, forKey: .onlyNamedPlaces) ?? true
        minimumVisitMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumVisitMinutes) ?? 5
        aiAssistant = try c.decodeIfPresent(Bool.self, forKey: .aiAssistant) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case locationLogging, calendarWriting, onlyNamedPlaces, minimumVisitMinutes, aiAssistant
    }
}

/// `public.user_settings` (primary key `user_id`, one row per user).
public struct UserSettingsRow: SyncRow, Equatable {
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
