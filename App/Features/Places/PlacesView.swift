import CalendarKit
import SharedModels
import SwiftUI

/// Recent visits with the spending matched to each, i.e. what gets written to the calendar.
struct PlacesView: View {
    let environment: AppEnvironment
    @State private var days: [DayGroup] = []

    struct DayGroup: Identifiable {
        let day: Date
        let rows: [Row]
        var id: Date { day }
    }

    struct Row: Identifiable {
        let visit: PlaceVisit
        let matches: [MatchedTransaction]
        let synced: Bool
        var id: String { visit.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if environment.cloudSync.hasLegacyVisitsInCloud && !environment.settings.visitSyncEnabled {
                    Section {
                        LegacyVisitsPrompt(environment: environment)
                    }
                }
                if !environment.settings.locationLoggingEnabled {
                    Section {
                        ContentUnavailableView {
                            Label("Location logging is off", systemImage: "location.slash")
                        } description: {
                            Text("Turn it on in Settings to log the places you visit and match them with your spending.")
                        }
                    }
                } else if days.isEmpty {
                    Section {
                        Text("No visits yet. iOS reports a visit after you've stayed somewhere for a few minutes, sometimes with a delay.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(days) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).day().month())) {
                        ForEach(group.rows) { row in
                            VisitRow(row: row)
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .refreshable {
                await environment.locationLogging.resolvePending()
                await environment.calendarSync.sync()
                reload()
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        let since = Date().addingTimeInterval(-CalendarSyncService.syncWindow)
        let stored = environment.visitRepository.visits(since: since)
        let visits = stored.map(\.domain)
        let transactions = environment.transactionRepository.transactions(from: since.addingTimeInterval(-86_400), to: Date().addingTimeInterval(3_600))
        let matches = VisitTransactionMatcher().match(visits: visits, transactions: transactions)
        let rows = zip(stored, visits).map { storedVisit, visit in
            Row(visit: visit, matches: matches[visit.id] ?? [], synced: storedVisit.calendarSyncedAt != nil)
        }
        let grouped = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.visit.arrival) }
        days = grouped.keys.sorted(by: >).map { day in
            let rows = (grouped[day] ?? []).sorted { lhs, rhs in lhs.visit.arrival > rhs.visit.arrival }
            return DayGroup(day: day, rows: rows)
        }
    }
}

private struct VisitRow: View {
    let row: PlacesView.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.visit.placeName ?? "Looking up place…")
                    .font(.body.weight(.medium))
                Spacer()
                if row.synced {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.green)
                        .accessibilityLabel("In calendar")
                }
            }
            Text(timeRange)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(row.matches, id: \.transaction.id) { match in
                Text("\(MoneyFormatting.signedString(for: match.transaction)) · \(match.transaction.merchant)\(match.confidence == .likely ? " (likely)" : "")")
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let start = row.visit.arrival.formatted(date: .omitted, time: .shortened)
        guard let departure = row.visit.departure else { return "Since \(start)" }
        return "\(start)–\(departure.formatted(date: .omitted, time: .shortened))"
    }
}
