import Foundation
import SwiftData

enum PersistenceController {
    /// The current schema. Add new models to a new schema version (SchemaVersions.swift).
    // Built once and never mutated.
    nonisolated(unsafe) static let schema = Schema(versionedSchema: SchemaV2.self)

    /// What happened when the store was opened.
    enum OpenResult: Equatable {
        /// Opened (and migrated if needed).
        case opened
        /// The store couldn't be opened or migrated. It was moved aside (kept, not deleted) and an
        /// empty store was created; everything must be fetched again.
        case recreated(movedTo: URL)
        /// Not even an empty store could be created on disk: running in memory for this launch.
        case inMemory
    }

    /// The store lives in the App Group container (when available) so app extensions can share it.
    static func makeContainer(appGroupID: String, inMemory: Bool) -> ModelContainer {
        open(appGroupID: appGroupID, inMemory: inMemory).container
    }

    static func open(appGroupID: String, inMemory: Bool) -> (container: ModelContainer, result: OpenResult) {
        if inMemory {
            return (memoryContainer(), .opened)
        }
        return open(at: storeURL(appGroupID: appGroupID))
    }

    static func storeURL(appGroupID: String) -> URL {
        if !appGroupID.isEmpty,
           let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent("DayLedger.store")
        }
        return ModelConfiguration().url
    }

    /// Opens the store at `url`, migrating it through `DayLedgerMigrationPlan`.
    ///
    /// 1. Migration plan (any store written by a released version).
    /// 2. Without the plan: a store from a development build that predates the versioned schema
    ///    is still opened by SwiftData's automatic lightweight migration.
    /// 3. Otherwise the store is corrupt or unreadable: it is moved aside, never deleted, and a
    ///    new one is created. Data synced to the account comes back on the next sync; the caller
    ///    resets sync bookkeeping (`resetSyncBookkeeping`) so everything is fetched again.
    static func open(at url: URL) -> (container: ModelContainer, result: OpenResult) {
        do {
            return (try container(at: url, migrationPlan: DayLedgerMigrationPlan.self), .opened)
        } catch {
            Log.persistence.error("Opening the store with the migration plan failed: \(String(describing: error), privacy: .public)")
        }
        do {
            return (try container(at: url, migrationPlan: nil), .opened)
        } catch {
            Log.persistence.error("Opening the store without the migration plan failed: \(String(describing: error), privacy: .public)")
        }
        let movedTo = moveAside(url)
        do {
            let container = try container(at: url, migrationPlan: DayLedgerMigrationPlan.self)
            Log.persistence.fault("The store was unreadable; started a new one and kept the old files next to it")
            return (container, .recreated(movedTo: movedTo))
        } catch {
            Log.persistence.fault("Couldn't create a new store; running in memory: \(String(describing: error), privacy: .public)")
            return (memoryContainer(), .inMemory)
        }
    }

    private static func container(at url: URL, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: ModelConfiguration(schema: schema, url: url))
    }

    private static func memoryContainer() -> ModelContainer {
        // An in-memory store with the current schema can't fail in practice.
        try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// Renames the store and its SQLite side files to `<name>.unreadable-<timestamp>[-wal|-shm]`.
    @discardableResult
    static func moveAside(_ url: URL, now: Date = Date()) -> URL {
        let manager = FileManager.default
        let suffix = ".unreadable-\(Int(now.timeIntervalSince1970))"
        let target = URL(fileURLWithPath: url.path + suffix)
        for extra in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + extra)
            guard manager.fileExists(atPath: source.path) else { continue }
            do {
                try manager.moveItem(at: source, to: URL(fileURLWithPath: target.path + extra))
            } catch {
                Log.persistence.error("Couldn't move \(source.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
            }
        }
        return target
    }

    /// After the store was recreated: forget what was already fetched, so the bank's recent
    /// history and the whole cloud copy are fetched again.
    static func resetSyncBookkeeping(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("cloud.cursor.") || key.hasPrefix("cloud.keyID.") || key == "bank.lastSuccessfulSync" {
            defaults.removeObject(forKey: key)
        }
    }
}
