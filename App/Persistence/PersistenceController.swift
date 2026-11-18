import Foundation
import SwiftData

enum PersistenceController {
    /// Every SwiftData model the app stores. Add new models here.
    static let schema = Schema([
        StoredTransaction.self,
        StoredVisit.self,
    ])

    /// The store lives in the App Group container (when available) so app extensions can share it.
    static func makeContainer(appGroupID: String, inMemory: Bool) -> ModelContainer {
        do {
            if inMemory {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
            if !appGroupID.isEmpty,
               let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
                let url = groupURL.appendingPathComponent("DayLedger.store")
                return try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            }
            return try ModelContainer(for: schema, configurations: ModelConfiguration())
        } catch {
            // A corrupt store must not brick the app: fall back to memory and let the next sync repopulate.
            assertionFailure("Failed to open store: \(error)")
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }
}
