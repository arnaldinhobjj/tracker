import Foundation

/// Whether money left or entered the account.
public enum TransactionDirection: String, Codable, Sendable, Hashable {
    case debit
    case credit
}

/// A bank transaction normalised from whichever aggregator produced it.
///
/// Amounts are stored as positive integers in minor units (pence) to avoid
/// floating point errors; `direction` says which way the money moved.
public struct BankTransaction: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier: `"<accountID>:<provider transaction id>"`.
    public var id: String
    public var accountID: String
    /// Human-friendly merchant name (cleaned up from the bank description when needed).
    public var merchant: String
    /// The raw description from the bank statement.
    public var rawDescription: String
    /// Always positive, in minor units (pence for GBP).
    public var amountMinor: Int
    /// ISO 4217 currency code, e.g. "GBP".
    public var currency: String
    public var direction: TransactionDirection
    /// The aggregator's own category, e.g. TrueLayer's "PURCHASE" or "TRANSFER".
    public var bankCategory: String
    public var category: SpendCategory
    public var timestamp: Date
    /// `false` when the bank only supplied a date (settled transactions often have no time).
    public var hasTime: Bool
    public var isPending: Bool

    public init(
        id: String,
        accountID: String,
        merchant: String,
        rawDescription: String,
        amountMinor: Int,
        currency: String = "GBP",
        direction: TransactionDirection,
        bankCategory: String,
        category: SpendCategory,
        timestamp: Date,
        hasTime: Bool,
        isPending: Bool
    ) {
        self.id = id
        self.accountID = accountID
        self.merchant = merchant
        self.rawDescription = rawDescription
        self.amountMinor = amountMinor
        self.currency = currency
        self.direction = direction
        self.bankCategory = bankCategory
        self.category = category
        self.timestamp = timestamp
        self.hasTime = hasTime
        self.isPending = isPending
    }

    /// Signed amount in minor units: negative for money out.
    public var signedAmountMinor: Int {
        direction == .debit ? -amountMinor : amountMinor
    }
}
