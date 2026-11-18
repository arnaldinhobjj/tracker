import SharedModels
import WidgetKit

struct SpendEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the snapshot the app wrote to the App Group. The widget does no networking:
/// the app refreshes the data and calls `WidgetCenter.reloadTimelines` when it changes.
struct SpendProvider: TimelineProvider {
    private var store: WidgetSnapshotStore? {
        let groupID = (Bundle.main.object(forInfoDictionaryKey: "DLAppGroupID") as? String) ?? ""
        return WidgetSnapshotStore(appGroupID: groupID)
    }

    func placeholder(in context: Context) -> SpendEntry {
        SpendEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholder : store?.load()
        completion(SpendEntry(date: Date(), snapshot: snapshot?.displayed(at: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let snapshot = store?.load()
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)

        // Two entries: now, and an empty day at midnight so yesterday's total never lingers.
        let entries = [
            SpendEntry(date: now, snapshot: snapshot?.displayed(at: now)),
            SpendEntry(date: midnight, snapshot: snapshot?.displayed(at: midnight)),
        ]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
}
