import Foundation
import SwiftData

// Every shipped shape of the store, so SwiftData can migrate any existing database step by step.
//
// Rules for changing the store:
// 1. Never edit a frozen version (SchemaV1, ...): it must match what is on users' devices.
// 2. Add a new version with the current models, and a stage in `DayLedgerMigrationPlan`.
// 3. Add a test to PersistenceMigrationTests that opens a store written by the previous version.

/// The store as shipped up to and including Sprint 1 (frozen copy of the models).
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredTransaction.self, StoredVisit.self] }

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
        var cloudSyncedAt: Date?

        init(id: String, accountID: String, merchant: String, rawDescription: String, amountMinor: Int, currency: String,
             directionRaw: String, bankCategory: String, categoryRaw: String, timestamp: Date, hasTime: Bool, isPending: Bool,
             updatedAt: Date, cloudSyncedAt: Date?) {
            self.id = id
            self.accountID = accountID
            self.merchant = merchant
            self.rawDescription = rawDescription
            self.amountMinor = amountMinor
            self.currency = currency
            self.directionRaw = directionRaw
            self.bankCategory = bankCategory
            self.categoryRaw = categoryRaw
            self.timestamp = timestamp
            self.hasTime = hasTime
            self.isPending = isPending
            self.updatedAt = updatedAt
            self.cloudSyncedAt = cloudSyncedAt
        }
    }

    @Model
    final class StoredVisit {
        @Attribute(.unique) var id: String
        var arrival: Date
        var departure: Date?
        var latitude: Double
        var longitude: Double
        var placeName: String?
        var placeCategory: String?
        var isNamedPlace: Bool
        var isResolved: Bool
        var calendarEventID: String?
        var calendarContentHash: String?
        var calendarSyncedAt: Date?
        var updatedAt: Date?
        var cloudSyncedAt: Date?

        init(id: String, arrival: Date, departure: Date?, latitude: Double, longitude: Double, isNamedPlace: Bool, isResolved: Bool,
             updatedAt: Date?, cloudSyncedAt: Date?) {
            self.id = id
            self.arrival = arrival
            self.departure = departure
            self.latitude = latitude
            self.longitude = longitude
            self.isNamedPlace = isNamedPlace
            self.isResolved = isResolved
            self.updatedAt = updatedAt
            self.cloudSyncedAt = cloudSyncedAt
        }
    }
}

/// Sprint 2: `needsCloudPush` on transactions and visits (found with a predicate instead of
/// loading every row on each sync) and `StoredPendingDeletion` (replaces the list in UserDefaults).
/// The current models are the top-level types.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredTransaction.self, StoredVisit.self, StoredPendingDeletion.self] }
}

enum DayLedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [v1ToV2] }

    /// Adds the new columns and entity (lightweight), then sets `needsCloudPush` from what V1 knew:
    /// a row needs uploading when it changed after it last matched the cloud, or never did.
    static var v1ToV2: MigrationStage { .custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            for transaction in try context.fetch(FetchDescriptor<StoredTransaction>()) {
                transaction.needsCloudPush = CloudMerge.isDirty(updatedAt: transaction.updatedAt, syncedAt: transaction.cloudSyncedAt)
            }
            for visit in try context.fetch(FetchDescriptor<StoredVisit>()) {
                visit.needsCloudPush = CloudMerge.isDirty(updatedAt: visit.updatedAt, syncedAt: visit.cloudSyncedAt)
            }
            try context.save()
        }
    ) }
}
