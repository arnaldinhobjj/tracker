import SharedModels
import SwiftUI
import WidgetKit

struct SpendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SpendEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.hasBankConnection {
                switch family {
                case .systemMedium: MediumView(snapshot: snapshot)
                case .accessoryRectangular: RectangularView(snapshot: snapshot)
                case .accessoryInline: InlineView(snapshot: snapshot)
                case .accessoryCircular: CircularView(snapshot: snapshot)
                default: SmallView(snapshot: snapshot)
                }
            } else {
                NotConnectedView(family: family)
            }
        }
        .widgetURL(URL(string: "dayledger://today"))
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

private func total(_ snapshot: WidgetSnapshot) -> String {
    MoneyFormatting.string(minorUnits: snapshot.totalSpentMinor, currencyCode: snapshot.currency)
}

private struct SmallView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HeaderLabel(needsReconnect: snapshot.needsReconnect)
            Text(total(snapshot))
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
            Spacer(minLength: 0)
            ForEach(snapshot.latest.prefix(2)) { item in
                HStack(spacing: 4) {
                    Text(item.merchant).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(item.formattedAmount).monospacedDigit().privacySensitive()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if snapshot.latest.isEmpty {
                Text("No spending yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MediumView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HeaderLabel(needsReconnect: snapshot.needsReconnect)
                Text(total(snapshot))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .privacySensitive()
                // Plural forms come from the String Catalog ("%lld transactions").
                Text("\(snapshot.transactionCount) transactions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if snapshot.latest.isEmpty {
                    Text("No spending yet today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.latest) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.symbolName)
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.merchant).font(.caption).lineLimit(1)
                            if let time = item.time {
                                Text(time, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 2)
                        Text(item.formattedAmount)
                            .font(.caption.monospacedDigit())
                            .privacySensitive()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RectangularView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Spent today")
                .font(.caption2)
                .widgetAccentable()
            Text(total(snapshot))
                .font(.headline.monospacedDigit())
                .privacySensitive()
            if let item = snapshot.latest.first {
                Text("\(item.merchant) \(item.formattedAmount)")
                    .font(.caption2)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        Label("\(total(snapshot)) today", systemImage: "sterlingsign.circle")
            .privacySensitive()
    }
}

private struct CircularView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "sterlingsign")
                    .font(.caption2)
                Text(compactTotal)
                    .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .privacySensitive()
            }
        }
        // The rounded "25" isn't meaningful on its own: read the exact amount.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Spent today, \(total(snapshot))"))
    }

    /// "£25" or "£1.2k": the circular widget only fits a few characters.
    private var compactTotal: String {
        let pounds = Double(snapshot.totalSpentMinor) / 100
        if pounds >= 1_000 { return String(format: "%.1fk", pounds / 1_000) }
        return String(format: "%.0f", pounds.rounded())
    }
}

private struct HeaderLabel: View {
    let needsReconnect: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if needsReconnect {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Bank needs reconnecting")
            }
        }
    }
}

private struct NotConnectedView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("DayLedger: open to connect")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sterlingsign")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("DayLedger: open to connect your bank"))
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "building.columns")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Open DayLedger to connect your bank")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
