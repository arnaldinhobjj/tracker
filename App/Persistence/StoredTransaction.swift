import Foundation
import SharedModels
import SwiftData

/// SwiftData cache of bank transactions, so the app works offline. Changing stored properties
/// needs a new schema version (see SchemaVersions.swift).
@Model
final class StoredTransaction {
    @Attribute(.unique) var id: String
    var accountID: String
    var merchant: String
    var rawDescription: String
    var amountMinor: Int
    var currency: String
    var directionRaw: String
    var bankCategory: String
    var categoryRaw: String
    var timestamp: Date
    var hasTime: Bool
    var isPending: Bool
    var updatedAt: Date
    /// When this row was last known to match the cloud copy (pushed or pulled). Nil: never synced.
    /// Optional so existing stores migrate without a default.
    var cloudSyncedAt: Date?
    /// True while this row has local changes the cloud doesn't have yet. Kept alongside the dates
    /// so the rows to upload can be fetched with a predicate (SchemaV2).
    var needsCloudPush: Bool = true

    init(_ transaction: BankTransaction, updatedAt: Date = Date()) {
        id = transaction.id
        accountID = transaction.accountID
        merchant = transaction.merchant
        rawDescription = transaction.rawDescription
        amountMinor = transaction.amountMinor
        currency = transaction.currency
        directionRaw = transaction.direction.rawValue
        bankCategory = transaction.bankCategory
        categoryRaw = transaction.category.rawValue
        timestamp = transaction.timestamp
        hasTime = transaction.hasTime
        isPending = transaction.isPending
        self.updatedAt = updatedAt
    }

    func update(from transaction: BankTransaction, at date: Date = Date()) {
        merchant = transaction.merchant
        rawDescription = transaction.rawDescription
        amountMinor = transaction.amountMinor
        currency = transaction.currency
        directionRaw = transaction.direction.rawValue
        bankCategory = transaction.bankCategory
        categoryRaw = transaction.category.rawValue
        timestamp = transaction.timestamp
        hasTime = transaction.hasTime
        isPending = transaction.isPending
        updatedAt = date
        needsCloudPush = true
    }

    var domain: BankTransaction {
        BankTransaction(
            id: id,
            accountID: accountID,
            merchant: merchant,
            rawDescription: rawDescription,
            amountMinor: amountMinor,
            currency: currency,
            direction: TransactionDirection(rawValue: directionRaw) ?? .debit,
            bankCategory: bankCategory,
            category: SpendCategory(rawValue: categoryRaw) ?? .other,
            timestamp: timestamp,
            hasTime: hasTime,
            isPending: isPending
        )
    }
}
