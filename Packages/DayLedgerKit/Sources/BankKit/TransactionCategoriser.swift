import Foundation
import SharedModels

/// Maps aggregator categories, classifications and merchant names onto `SpendCategory`.
public enum TransactionCategoriser {
    public static func categorise(
        bankCategory: String,
        classification: [String],
        merchant: String,
        direction: TransactionDirection
    ) -> SpendCategory {
        let bank = bankCategory.uppercased()
        let merchantText = merchant.lowercased()
        let classText = classification.joined(separator: " ").lowercased()

        if bank == "TRANSFER" { return .transfer }
        if direction == .credit {
            // Refunds keep the category of the original purchase; other credits are income.
            if bank == "PURCHASE" || bank == "CORRECTION" {
                return match(merchantText, merchantKeywords) ?? match(classText, classificationKeywords) ?? .other
            }
            return .income
        }
        if bank == "ATM" || bank == "CASH" { return .cash }

        if let category = match(merchantText, merchantKeywords) { return category }
        if let category = match(classText, classificationKeywords) { return category }

        switch bank {
        case "DIRECT_DEBIT", "BILL_PAYMENT", "STANDING_ORDER", "FEE_CHARGE", "INTEREST":
            return .bills
        default:
            return .other
        }
    }

    private static func match(_ text: String, _ table: [(SpendCategory, [String])]) -> SpendCategory? {
        guard !text.isEmpty else { return nil }
        for (category, keywords) in table where keywords.contains(where: { text.contains($0) }) {
            return category
        }
        return nil
    }

    /// Well-known UK merchants. Checked before classifications because they are more specific
    /// (TrueLayer files coffee shops under "Food & Dining").
    static let merchantKeywords: [(SpendCategory, [String])] = [
        (.coffee, ["costa", "starbucks", "pret a manger", "caffe nero", "caffè nero", "coffee", "espresso", "black sheep"]),
        (.groceries, ["tesco", "sainsbury", "asda", "morrisons", "aldi", "lidl", "waitrose", "co-op", "coop",
                      "ocado", "iceland", "m&s food", "marks & spencer food", "spar", "budgens", "farmfoods"]),
        (.eatingOut, ["mcdonald", "greggs", "nando", "kfc", "burger king", "deliveroo", "just eat", "uber eats",
                      "wagamama", "pizza", "subway", "leon", "itsu", "wasabi", "five guys", "pub", "restaurant"]),
        (.transport, ["tfl", "transport for london", "trainline", "national rail", "lner", "avanti", "gwr",
                      "uber", "bolt", "addison lee", "shell", "bp ", "esso", "texaco", "parking", "ringgo", "paybyphone"]),
        (.health, ["puregym", "pure gym", "the gym", "david lloyd", "nuffield", "virgin active", "better gym",
                   "boots", "superdrug", "pharmacy", "dentist"]),
        (.entertainment, ["netflix", "spotify", "disney", "odeon", "vue", "cineworld", "everyman", "ticketmaster", "steam"]),
        (.travel, ["easyjet", "ryanair", "british airways", "airbnb", "booking.com", "premier inn", "travelodge", "hotel"]),
        (.shopping, ["amazon", "argos", "john lewis", "currys", "primark", "zara", "h&m", "next ", "uniqlo", "ikea", "ebay"]),
        (.bills, ["council tax", "british gas", "octopus energy", "edf", "thames water", "ee ", "vodafone", "o2 ",
                  "three", "sky ", "virgin media", "bt ", "insurance"]),
    ]

    static let classificationKeywords: [(SpendCategory, [String])] = [
        (.coffee, ["coffee"]),
        (.groceries, ["groceries", "supermarket"]),
        (.eatingOut, ["restaurant", "fast food", "dining", "takeaway", "bars", "pubs", "food"]),
        (.transport, ["transport", "taxi", "fuel", "gas & fuel", "parking", "auto"]),
        (.travel, ["travel", "hotel", "air travel", "vacation"]),
        (.health, ["health", "fitness", "gym", "pharmacy", "doctor", "dentist", "sports"]),
        (.entertainment, ["entertainment", "movies", "music", "arts", "amusement"]),
        (.bills, ["bills", "utilities", "mobile phone", "internet", "insurance", "rent", "mortgage"]),
        (.shopping, ["shopping", "clothing", "electronics", "books", "home"]),
    ]
}
