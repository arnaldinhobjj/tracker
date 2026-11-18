import Foundation

/// DayLedger's own spending categories. Bank categories are mapped onto these.
public enum SpendCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case groceries
    case eatingOut
    case coffee
    case transport
    case shopping
    case bills
    case entertainment
    case health
    case travel
    case cash
    case transfer
    case income
    case other

    public var displayName: String {
        switch self {
        case .groceries: return "Groceries"
        case .eatingOut: return "Eating out"
        case .coffee: return "Coffee"
        case .transport: return "Transport"
        case .shopping: return "Shopping"
        case .bills: return "Bills"
        case .entertainment: return "Entertainment"
        case .health: return "Health & fitness"
        case .travel: return "Travel"
        case .cash: return "Cash"
        case .transfer: return "Transfer"
        case .income: return "Income"
        case .other: return "Other"
        }
    }

    /// SF Symbol name used in lists and widgets.
    public var symbolName: String {
        switch self {
        case .groceries: return "cart"
        case .eatingOut: return "fork.knife"
        case .coffee: return "cup.and.saucer"
        case .transport: return "tram"
        case .shopping: return "bag"
        case .bills: return "doc.text"
        case .entertainment: return "ticket"
        case .health: return "heart"
        case .travel: return "airplane"
        case .cash: return "banknote"
        case .transfer: return "arrow.left.arrow.right"
        case .income: return "arrow.down.circle"
        case .other: return "creditcard"
        }
    }

    /// Categories where the purchase usually happens in person. Used to decide
    /// whether a transaction may be matched to a visit on time alone.
    public var isTypicallyInPerson: Bool {
        switch self {
        case .groceries, .eatingOut, .coffee, .shopping, .health, .cash:
            return true
        // Entertainment is often a subscription (Netflix, Spotify), so it needs a name match.
        case .entertainment, .transport, .bills, .travel, .transfer, .income, .other:
            return false
        }
    }
}
