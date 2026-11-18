import BankKit
import Foundation
import SharedModels
import WidgetKit

/// Writes the widget snapshot to the App Group and asks WidgetKit to reload,
/// but only when the content actually changed (reloads are budgeted by iOS).
@MainActor
final class WidgetPublisher {
    private let store: WidgetSnapshotStore?
    private let repository: TransactionRepository
    private let bank: BankService
    private let reload: () -> Void

    init(store: WidgetSnapshotStore?, repository: TransactionRepository, bank: BankService,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind) }) {
        self.store = store
        self.repository = repository
        self.bank = bank
        self.reload = reload
    }

    @discardableResult
    func publish(now: Date = Date()) -> Bool {
        guard let store else { return false }
        let connections = bank.connections()
        let snapshot = WidgetSnapshot.make(
            from: repository.transactions(on: now),
            now: now,
            hasBankConnection: !connections.isEmpty,
            needsReconnect: connections.contains { $0.needsReconnect }
        )
        if let previous = store.load(), previous.hasSameContent(as: snapshot) {
            return false
        }
        do {
            try store.save(snapshot)
            reload()
            return true
        } catch {
            return false
        }
    }

    func clear() {
        store?.delete()
        reload()
    }
}
