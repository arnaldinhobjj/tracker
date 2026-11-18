import Foundation

public enum MoneyFormatting {
    /// Formats minor units as a currency string, e.g. 340 -> "£3.40".
    public static func string(minorUnits: Int, currencyCode: String = "GBP", locale: Locale = Locale(identifier: "en_GB")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = locale
        let value = Decimal(minorUnits) / 100
        return formatter.string(from: value as NSDecimalNumber) ?? "\(currencyCode) \(value)"
    }

    /// Formats a transaction amount with a leading "+" for money in.
    public static func signedString(for transaction: BankTransaction) -> String {
        let base = string(minorUnits: transaction.amountMinor, currencyCode: transaction.currency)
        return transaction.direction == .credit ? "+\(base)" : base
    }

    /// Converts a decimal amount from an API (e.g. -3.4) into positive minor units (340).
    public static func minorUnits(fromMajor amount: Double) -> Int {
        // Go through the shortest decimal description to avoid binary rounding (3.4 -> 3.39999...).
        let decimal = Decimal(string: String(abs(amount))) ?? Decimal(abs(amount))
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
