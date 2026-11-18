import Foundation

/// What the user's DayLedger Pro subscription allows, as returned by the `verify-subscription` and
/// `entitlement` Edge Functions:
/// `{"active":true,"status":"trial","expiresAt":"2026-11-25T10:00:00Z","isTrial":true,"productId":"app.dayledger.pro.monthly"}`
public struct Entitlement: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case trial
        case active
        case gracePeriod = "grace_period"
        case billingRetry = "billing_retry"
        case expired
        case revoked
        case refunded
        /// The user has never subscribed.
        case none
        /// A status this version of the app doesn't know yet.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }

        /// Statuses that unlock the app (the contract's `has_active_entitlement`).
        public var unlocksApp: Bool {
            switch self {
            case .trial, .active, .gracePeriod: return true
            default: return false
            }
        }
    }

    public var active: Bool
    public var status: Status
    public var expiresAt: Date?
    public var isTrial: Bool
    public var productId: String?

    public init(active: Bool, status: Status, expiresAt: Date?, isTrial: Bool, productId: String?) {
        self.active = active
        self.status = status
        self.expiresAt = expiresAt
        self.isTrial = isTrial
        self.productId = productId
    }

    public static let none = Entitlement(active: false, status: .none, expiresAt: nil, isTrial: false, productId: nil)

    /// True when the subscription unlocks the app right now. An expiry in the past wins over a
    /// stale `active` flag (e.g. a cached entitlement read while offline).
    public func isEntitled(now: Date = Date()) -> Bool {
        guard active, status.unlocksApp || status == .unknown else { return false }
        if let expiresAt { return expiresAt > now }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case active, status, expiresAt, isTrial, productId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? (active ? .active : .none)
        isTrial = try container.decodeIfPresent(Bool.self, forKey: .isTrial) ?? (status == .trial)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        if let raw = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = ISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            expiresAt = date
        } else {
            expiresAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(expiresAt.map(ISO8601.string(from:)), forKey: .expiresAt)
        try container.encode(isTrial, forKey: .isTrial)
        try container.encode(productId, forKey: .productId)
    }
}

/// ISO 8601 / RFC 3339 dates as Supabase writes them: with or without fractional seconds, and
/// with `Z` or a numeric offset (Postgres `timestamptz` JSON looks like `2026-11-18T10:00:00.123456+00:00`).
public enum ISO8601 {
    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = makeFormatter(fractional: true).date(from: trimmed) { return date }
        if let date = makeFormatter(fractional: false).date(from: trimmed) { return date }
        // Microseconds (Postgres) are cut to milliseconds, which every formatter version accepts.
        if let dot = trimmed.firstIndex(of: ".") {
            let digits = trimmed[trimmed.index(after: dot)...].prefix { $0.isNumber }
            if digits.count > 3 {
                let rest = trimmed[digits.endIndex...]
                let shortened = String(trimmed[..<dot]) + "." + String(digits.prefix(3)) + String(rest)
                if let date = makeFormatter(fractional: true).date(from: shortened) { return date }
            }
        }
        // Postgres can also use a space instead of "T".
        if trimmed.count > 10, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 10)] == " " {
            var replaced = trimmed
            let index = replaced.index(replaced.startIndex, offsetBy: 10)
            replaced.replaceSubrange(index...index, with: "T")
            return date(from: replaced)
        }
        return nil
    }

    /// Always UTC with milliseconds, e.g. `2026-11-18T10:00:00.123Z`.
    public static func string(from date: Date) -> String {
        makeFormatter(fractional: true).string(from: date)
    }

    // ISO8601DateFormatter is thread-safe but not Sendable; a fresh one per call keeps this simple.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}
