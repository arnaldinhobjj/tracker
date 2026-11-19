import Foundation
import SharedModels
import SwiftData

/// A transaction removed on this device (a pending payment replaced when it settled) whose
/// deletion hasn't reached the cloud yet. Kept in SwiftData since SchemaV2; earlier versions kept a
/// capped list in UserDefaults, which could silently drop deletions.
@Model
final class StoredPendingDeletion {
    @Attribute(.unique) var id: String
    /// The deleted transaction (JSON), needed to send an encrypted tombstone.
    var transactionData: Data
    var deletedAt: Date

    init(transaction: BankTransaction, deletedAt: Date) {
        id = transaction.id
        // Encoding a value type of strings, numbers and dates can't fail.
        transactionData = (try? JSONEncoder().encode(transaction)) ?? Data()
        self.deletedAt = deletedAt
    }

    var transaction: BankTransaction? {
        try? JSONDecoder().decode(BankTransaction.self, from: transactionData)
    }
}
