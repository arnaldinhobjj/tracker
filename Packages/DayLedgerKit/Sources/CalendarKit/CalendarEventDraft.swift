import Foundation

/// An event DayLedger wants in Google Calendar. `id` is deterministic, so writing the same
/// draft twice updates one event instead of creating a duplicate.
public struct CalendarEventDraft: Equatable, Sendable {
    public var id: String
    public var summary: String
    public var description: String
    public var start: Date
    public var end: Date
    public var timeZone: TimeZone
    public var location: String?
    /// Stored in the event's `extendedProperties.private`, e.g. the source visit ID.
    public var privateProperties: [String: String]
    /// Visit logs are "free" so they don't block your availability; suggested plans are "busy".
    public var showsAsBusy: Bool

    public init(id: String, summary: String, description: String, start: Date, end: Date, timeZone: TimeZone,
                location: String? = nil, privateProperties: [String: String] = [:], showsAsBusy: Bool = false) {
        self.id = id
        self.summary = summary
        self.description = description
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.location = location
        self.privateProperties = privateProperties
        self.showsAsBusy = showsAsBusy
    }

    /// Hash of everything that ends up in Google Calendar. If it hasn't changed since the last
    /// write, the event doesn't need updating.
    public var contentHash: String {
        let parts = [id, summary, description, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
                     timeZone.identifier, location ?? "", showsAsBusy ? "busy" : "free",
                     privateProperties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
        return StableHash.hex(parts.joined(separator: "|"))
    }
}

public enum CalendarEventID {
    /// Google event IDs may only use base32hex characters (a–v, 0–9) and must be 5–1024 long.
    /// Prefixes keep the kinds apart: "dlv" = visit, "dla" = AI suggestion.
    public static func forVisit(_ visitID: String) -> String {
        "dlv" + sanitise(visitID)
    }

    public static func forSuggestion(key: String) -> String {
        "dla" + StableHash.hex(key) + StableHash.hex("salt:" + key)
    }

    static func sanitise(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = Set("0123456789abcdefghijklmnopqrstuv")
        let kept = lowered.filter { allowed.contains($0) }
        // If the raw ID had characters outside base32hex (w–z, symbols), fall back to a hash
        // so two different IDs can't collapse into the same event ID.
        return kept.count == lowered.filter({ $0 != "-" }).count && kept.count >= 8 ? kept : StableHash.hex(raw) + StableHash.hex("v:" + raw)
    }

    public static func isValid(_ id: String) -> Bool {
        let allowed = Set("0123456789abcdefghijklmnopqrstuv")
        return (5...1024).contains(id.count) && id.allSatisfy { allowed.contains($0) }
    }
}

/// FNV-1a 64-bit. Stable across launches and platforms (unlike `Hasher`), and not a security hash.
public enum StableHash {
    public static func hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
