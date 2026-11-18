import Foundation

/// Cleans bank statement descriptions ("SQ *JOE'S COFFEE 1234 LONDON GB") into
/// readable names ("Joe's Coffee") and produces comparable tokens for matching.
public enum MerchantNameNormaliser {
    /// Payment-processor and card-scheme prefixes that hide the real merchant.
    static let prefixes = [
        "CARD PAYMENT TO ", "CONTACTLESS PAYMENT ", "CONTACTLESS ", "PURCHASE AT ", "PAYMENT TO ",
        "SQ *", "SQ*", "SUMUP *", "SUMUP*", "SUM UP *", "ZTL*", "ZTL *", "IZ *", "IZ*", "PAYPAL *", "PAYPAL*",
        "CRV*", "SP * ", "SP *", "SP ", "VIS ", "POS ", "DD ", "SO ", "BGC ",
    ]

    /// Words that carry no identity ("the", company suffixes, places, countries).
    static let stopWords: Set<String> = [
        "the", "ltd", "limited", "plc", "llp", "inc", "co", "uk", "gb", "gbr", "gbp", "london", "store",
        "stores", "shop", "branch", "and", "of", "at", "on", "www", "com", "card", "payment", "contactless",
    ]

    static let trailingPlaces: Set<String> = [
        "LONDON", "MANCHESTER", "BIRMINGHAM", "LEEDS", "GLASGOW", "EDINBURGH", "BRISTOL", "LIVERPOOL",
        "CARDIFF", "BELFAST", "SHEFFIELD", "NEWCASTLE", "NOTTINGHAM", "LEICESTER", "BRIGHTON", "OXFORD", "CAMBRIDGE",
    ]

    /// A display-friendly merchant name.
    public static func displayName(from description: String) -> String {
        var text = description.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        // "TESCO STORES 1234 ON 12 MAR" -> drop everything from " ON <digit>" onwards.
        if let range = text.range(of: #" ON \d"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        let words = text
            .split(separator: " ")
            .map(String.init)
            .filter { word in
                !word.contains(where: \.isNumber) && !["GB", "GBR", "UK", "GBP"].contains(word)
            }
        var kept = words
        // Card descriptions often end with the town: "COSTA COFFEE LONDON".
        while kept.count > 1, let last = kept.last, trailingPlaces.contains(last) {
            kept.removeLast()
        }
        let cleaned = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return description.trimmingCharacters(in: .whitespaces) }
        return cleaned.capitalized
    }

    /// Lower-cased identity tokens used to compare a merchant with a place name.
    public static func tokens(_ text: String) -> [String] {
        let display = displayName(from: text).lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "&", with: " ")
        return display
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Similarity between two names in 0...1 (token overlap, with prefix matching for
    /// abbreviations like "Sainsburys" vs "Sainsbury's Local").
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = Set(tokens(a))
        let right = Set(tokens(b))
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        func matches(_ x: String, _ y: String) -> Bool {
            if x == y { return true }
            let minLength = min(x.count, y.count)
            guard minLength >= 4 else { return false }
            return x.hasPrefix(y) || y.hasPrefix(x)
        }

        let matched = left.filter { l in right.contains { r in matches(l, r) } }.count
        // Divide by the smaller set: "Costa" vs "Costa Coffee" is a strong match.
        return Double(matched) / Double(min(left.count, right.count))
    }
}
