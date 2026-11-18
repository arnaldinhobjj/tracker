import SharedModels
import SwiftUI

struct TransactionRow: View {
    let transaction: BankTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(subtitle)
                    if transaction.isPending {
                        Text("· Pending")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(MoneyFormatting.signedString(for: transaction))
                .font(.body.monospacedDigit())
                .foregroundStyle(transaction.direction == .credit ? Color.green : Color.primary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transactionRow")
    }

    private var subtitle: String {
        let time = transaction.hasTime ? transaction.timestamp.formatted(date: .omitted, time: .shortened) : "Today"
        return "\(time) · \(transaction.category.displayName)"
    }
}
