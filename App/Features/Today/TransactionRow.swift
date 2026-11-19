import SharedModels
import SwiftUI

struct TransactionRow: View {
    let transaction: BankTransaction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    /// At accessibility text sizes the amount goes under the merchant instead of squeezing it.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = isStacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Image(systemName: transaction.category.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: iconSize, height: iconSize)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                    .font(.body)
                    .lineLimit(isStacked ? nil : 1)
                HStack(spacing: 4) {
                    Text(subtitle)
                    if transaction.isPending {
                        Text("· Pending")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !isStacked {
                Spacer(minLength: 8)
            }

            Text(MoneyFormatting.signedString(for: transaction))
                .font(.body.monospacedDigit())
                .foregroundStyle(transaction.direction == .credit ? Color.green : Color.primary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // Colour alone doesn't say money came in: VoiceOver says so.
        .accessibilityValue(transaction.direction == .credit ? Text("Money in") : Text(""))
        .accessibilityIdentifier("transactionRow")
    }

    private var subtitle: String {
        let time = transaction.hasTime ? transaction.timestamp.formatted(date: .omitted, time: .shortened) : String(localized: "Today")
        return "\(time) · \(transaction.category.displayName)"
    }
}
