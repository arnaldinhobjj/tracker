import Foundation

/// The one place that decides what syncs, and in which order.
///
/// Every trigger (app foregrounded, background refresh, a visit arriving, a bank sync finishing,
/// a sign-in, a new subscription) asks for the *steps* it needs. Steps always run in the same order
/// (bank → places → widget → calendar → entitlement → cloud), and requests that arrive while a
/// pass is running are merged: a step that is still to come in the current pass isn't run twice,
/// and anything else runs in one follow-up pass. Before this, each trigger called the services
/// itself, so a single app launch could start several overlapping bank, calendar and cloud runs.
@MainActor
final class SyncCoordinator {
    struct Steps: OptionSet, Hashable, Sendable, CustomStringConvertible {
        let rawValue: Int

        /// Fetch transactions from the bank (also triggers widget, calendar and cloud).
        static let bank = Steps(rawValue: 1 << 0)
        /// Retry place-name lookups that failed (e.g. offline).
        static let places = Steps(rawValue: 1 << 1)
        static let widget = Steps(rawValue: 1 << 2)
        static let calendar = Steps(rawValue: 1 << 3)
        /// Ask the server about the subscription (signed in only).
        static let entitlement = Steps(rawValue: 1 << 4)
        static let cloud = Steps(rawValue: 1 << 5)

        static let all: Steps = [.bank, .places, .widget, .calendar, .entitlement, .cloud]
        /// Pipeline order: later steps use what earlier ones produced.
        static let order: [Steps] = [.bank, .places, .widget, .calendar, .entitlement, .cloud]

        var description: String {
            let names: [(Steps, String)] = [(.bank, "bank"), (.places, "places"), (.widget, "widget"), (.calendar, "calendar"),
                                            (.entitlement, "entitlement"), (.cloud, "cloud")]
            return names.filter { contains($0.0) }.map(\.1).joined(separator: "+")
        }
    }

    private let perform: @MainActor (Steps) async -> Void
    /// Requested but not started.
    private var pending: Steps = []
    /// Steps of the running pass that haven't started yet.
    private var upcoming: Steps = []
    private var runner: Task<Void, Never>?
    /// Number of passes run (for tests and logs).
    private(set) var passCount = 0

    /// `perform` runs exactly one step at a time.
    init(perform: @escaping @MainActor (Steps) async -> Void) {
        self.perform = perform
    }

    var isRunning: Bool { runner != nil }

    /// Asks for `steps` and waits until they have run.
    func request(_ steps: Steps) async {
        enqueue(steps)
        await runner?.value
    }

    /// Asks for `steps` without waiting.
    func schedule(_ steps: Steps) {
        enqueue(steps)
    }

    private func enqueue(_ steps: Steps) {
        let new = steps.subtracting(upcoming)
        guard !new.isEmpty else { return }
        pending.formUnion(new)
        if runner == nil {
            runner = Task { await drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let pass = pending
            pending = []
            upcoming = pass
            passCount += 1
            Log.sync.debug("Sync pass \(self.passCount, privacy: .public): \(pass.description, privacy: .public)")
            for step in Steps.order where pass.contains(step) {
                // Removed before running: a request for this step made while it runs (new data
                // arrived mid-step) gets a fresh run in the next pass.
                upcoming.remove(step)
                await perform(step)
            }
        }
        upcoming = []
        runner = nil
    }
}
