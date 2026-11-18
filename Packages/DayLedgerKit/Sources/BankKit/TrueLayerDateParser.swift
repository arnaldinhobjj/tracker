import Foundation

/// Parses TrueLayer timestamps, which vary by bank:
/// "2024-03-06T00:00:00", "2024-03-06T09:14:00+00:00", "2024-03-06T09:14:22.1234567Z".
/// A time of exactly "00:00:00" is treated as "date only" (no time of day known).
public enum TrueLayerDateParser {
    public struct ParsedDate: Equatable, Sendable {
        public let date: Date
        public let hasTime: Bool
    }

    public static func parse(_ string: String, defaultTimeZone: TimeZone = TimeZone(identifier: "Europe/London")!) -> ParsedDate? {
        var text = string.trimmingCharacters(in: .whitespaces)

        // Trim fractional seconds to milliseconds; ISO8601DateFormatter rejects longer fractions.
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            let fraction = text[range].prefix(4) // "." + 3 digits
            text.replaceSubrange(range, with: fraction)
        }

        let hasZone = text.hasSuffix("Z") || text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        let date: Date?
        if hasZone {
            date = isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
        } else {
            // No offset: the bank means UK local time.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = defaultTimeZone
            formatter.dateFormat = text.contains(".") ? "yyyy-MM-dd'T'HH:mm:ss.SSS" : "yyyy-MM-dd'T'HH:mm:ss"
            date = formatter.date(from: text) ?? {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.date(from: String(text.prefix(10)))
            }()
        }
        guard let date else { return nil }

        // Banks that only know the posting date send "T00:00:00" (with or without an offset).
        let looksDateOnly = string.count <= 10
            || string.range(of: #"T00:00:00(\.0+)?([Zz]|[+-]\d{2}:?\d{2})?$"#, options: .regularExpression) != nil
        return ParsedDate(date: date, hasTime: !looksDateOnly)
    }

    /// Formats a date for TrueLayer's `from`/`to` query parameters.
    public static func queryString(_ date: Date) -> String {
        isoPlain.string(from: date)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
