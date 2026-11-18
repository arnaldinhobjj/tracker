import Foundation
import SharedModels

/// Turns a visit and its matched transactions into a calendar event, e.g.
/// "At Costa Coffee · £3.40", 09:10–09:45, with the purchases in the description.
public struct VisitEventBuilder: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func draft(for visit: PlaceVisit, matches: [MatchedTransaction]) -> CalendarEventDraft? {
        guard let departure = visit.departure else { return nil }
        let place = visit.placeName ?? "Unknown place"
        let sorted = matches.sorted { $0.transaction.timestamp < $1.transaction.timestamp }
        let netSpend = SpendingCalculator.netSpendMinor(sorted.map(\.transaction))
        let currency = sorted.first?.transaction.currency ?? "GBP"

        var summary = "At \(place)"
        if netSpend > 0 {
            summary += " · \(MoneyFormatting.string(minorUnits: netSpend, currencyCode: currency))"
        }

        var lines: [String] = ["\(time(visit.arrival))–\(time(departure)) at \(place)"]
        if let category = visit.categoryName {
            lines[0] += " (\(category))"
        }
        for match in sorted {
            let transaction = match.transaction
            let amount = MoneyFormatting.string(minorUnits: transaction.amountMinor, currencyCode: transaction.currency)
            let verb = SpendingCalculator.isRefund(transaction) ? "Refund" : "Spent"
            var line = "\(verb) \(amount) at \(transaction.merchant)"
            if transaction.hasTime { line += " (\(time(transaction.timestamp)))" }
            if transaction.isPending { line += ", pending" }
            if match.confidence == .likely { line += ", likely match" }
            lines.append(line)
        }
        if sorted.count > 1 {
            lines.append("Total: \(MoneyFormatting.string(minorUnits: netSpend, currencyCode: currency))")
        }
        lines.append("")
        lines.append("Logged automatically by DayLedger.")

        return CalendarEventDraft(
            id: CalendarEventID.forVisit(visit.id),
            summary: summary,
            description: lines.joined(separator: "\n"),
            start: visit.arrival,
            end: departure,
            timeZone: timeZone,
            location: visit.isNamedPlace ? place : nil,
            privateProperties: ["dayledgerKind": "visit", "dayledgerVisitID": visit.id],
            showsAsBusy: false
        )
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
