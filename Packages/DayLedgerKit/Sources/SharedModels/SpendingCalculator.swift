import Foundation

/// Rules for what counts as "spent".
///
/// - Debits count as spending, except transfers (moving money between accounts).
/// - Refunds (credits the bank marks as a purchase or a correction) reduce spending.
/// - Other credits (salary, interest, incoming transfers) are ignored.
public enum SpendingCalculator {
    static let refundBankCategories: Set<String> = ["PURCHASE", "CORRECTION"]

    public static func isSpend(_ transaction: BankTransaction) -> Bool {
        transaction.direction == .debit && transaction.category != .transfer
    }

    public static func isRefund(_ transaction: BankTransaction) -> Bool {
        transaction.direction == .credit && refundBankCategories.contains(transaction.bankCategory.uppercased())
    }

    /// Net spend in minor units for the given transactions.
    public static func netSpendMinor(_ transactions: [BankTransaction]) -> Int {
        transactions.reduce(0) { total, transaction in
            if isSpend(transaction) { return total + transaction.amountMinor }
            if isRefund(transaction) { return total - transaction.amountMinor }
            return total
        }
    }

    /// Transactions that fall on the same calendar day as `day`, newest first.
    public static func transactions(_ transactions: [BankTransaction], on day: Date, calendar: Calendar = .current) -> [BankTransaction] {
        transactions
            .filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Net spend for the calendar day containing `day`.
    public static func netSpendMinor(_ transactions: [BankTransaction], on day: Date, calendar: Calendar = .current) -> Int {
        netSpendMinor(self.transactions(transactions, on: day, calendar: calendar))
    }
}
