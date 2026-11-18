import SharedModels
import SwiftUI
import WidgetKit

@main
struct DayLedgerWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpendWidget()
    }
}

struct SpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: SpendProvider()) { entry in
            SpendWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's spending")
        .description("Your total spend today and the latest transactions.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

#Preview(as: .systemMedium) {
    SpendWidget()
} timeline: {
    SpendEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .accessoryRectangular) {
    SpendWidget()
} timeline: {
    SpendEntry(date: .now, snapshot: .placeholder)
}
