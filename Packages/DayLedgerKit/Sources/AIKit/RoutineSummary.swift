import Foundation
import SharedModels

/// The only data ever sent to an AI provider. Built to be minimal and anonymised:
/// - named places only (businesses/landmarks), never street addresses or coordinates
/// - visit patterns as weekday + hour counts, not individual timestamps
/// - spending as weekly averages per category, rounded to £5, never individual transactions,
///   merchants' raw descriptions, account IDs or balances
/// - calendar as busy/free blocks only, never titles, attendees or locations
public struct RoutineSummary: Codable, Equatable, Sendable {
    public struct TimeSlot: Codable, Equatable, Sendable {
        public var weekday: String
        public var hour: Int
        public var count: Int
    }

    public struct Place: Codable, Equatable, Sendable {
        public var name: String
        public var category: String?
        public var visitsInPeriod: Int
        public var typicalDurationMinutes: Int
        /// Most common weekday/hour combinations, most frequent first.
        public var typicalSlots: [TimeSlot]
    }

    public struct Spending: Codable, Equatable, Sendable {
        public var category: String
        public var weeklyAverageRoundedGBP: Int
    }

    public struct BusyBlock: Codable, Equatable, Sendable {
        public var start: String
        public var end: String
    }

    public var today: String
    public var timeZone: String
    public var periodDays: Int
    public var places: [Place]
    public var spending: [Spending]
    /// Existing commitments in the planning window, as busy times only.
    public var busy: [BusyBlock]
    public var planningWindowDays: Int
}

public struct RoutineSummaryBuilder: Sendable {
    public var periodDays: Int
    public var planningWindowDays: Int
    public var maxPlaces: Int
    public var calendar: Calendar

    public init(periodDays: Int = 28, planningWindowDays: Int = 14, maxPlaces: Int = 15, calendar: Calendar = .current) {
        self.periodDays = periodDays
        self.planningWindowDays = planningWindowDays
        self.maxPlaces = maxPlaces
        self.calendar = calendar
    }

    public func build(visits: [PlaceVisit], transactions: [BankTransaction], busy: [DateInterval], now: Date) -> RoutineSummary {
        let periodStart = now.addingTimeInterval(-TimeInterval(periodDays) * 86_400)
        let planningEnd = now.addingTimeInterval(TimeInterval(planningWindowDays) * 86_400)

        // Places: named points of interest only. Addresses could identify your home or friends.
        let recentNamed = visits.filter { $0.isNamedPlace && $0.arrival >= periodStart && $0.arrival <= now && $0.placeName != nil }
        let byName = Dictionary(grouping: recentNamed) { $0.placeName! }
        let places = byName.map { name, visits -> RoutineSummary.Place in
            var slotCounts: [String: (weekday: String, hour: Int, count: Int)] = [:]
            for visit in visits {
                let weekday = weekdayName(visit.arrival)
                let hour = calendar.component(.hour, from: visit.arrival)
                let key = "\(weekday)-\(hour)"
                slotCounts[key, default: (weekday, hour, 0)].count += 1
            }
            let slots = slotCounts.values
                .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }
                .prefix(4)
                .map { RoutineSummary.TimeSlot(weekday: $0.weekday, hour: $0.hour, count: $0.count) }
            let durations = visits.compactMap(\.duration)
            let average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
            return RoutineSummary.Place(
                name: name,
                category: visits.first?.categoryName,
                visitsInPeriod: visits.count,
                typicalDurationMinutes: Int((average / 60 / 5).rounded()) * 5,
                typicalSlots: Array(slots)
            )
        }
        .sorted { $0.visitsInPeriod != $1.visitsInPeriod ? $0.visitsInPeriod > $1.visitsInPeriod : $0.name < $1.name }
        .prefix(maxPlaces)

        // Spending: weekly average per category, rounded to £5. No merchants, no individual amounts.
        let weeks = Double(periodDays) / 7
        let recentSpend = transactions.filter { $0.timestamp >= periodStart && $0.timestamp <= now && SpendingCalculator.isSpend($0) }
        let spending = Dictionary(grouping: recentSpend, by: \.category)
            .map { category, items -> RoutineSummary.Spending in
                let pounds = Double(items.reduce(0) { $0 + $1.amountMinor }) / 100 / weeks
                return RoutineSummary.Spending(category: category.displayName, weeklyAverageRoundedGBP: Int((pounds / 5).rounded()) * 5)
            }
            .filter { $0.weeklyAverageRoundedGBP > 0 }
            .sorted { $0.weeklyAverageRoundedGBP != $1.weeklyAverageRoundedGBP ? $0.weeklyAverageRoundedGBP > $1.weeklyAverageRoundedGBP : $0.category < $1.category }

        // Busy blocks in the planning window, rounded outwards to 15 minutes.
        let blocks = busy
            .filter { $0.end > now && $0.start < planningEnd }
            .map { RoutineSummary.BusyBlock(start: iso(roundDown($0.start)), end: iso(roundUp($0.end))) }

        return RoutineSummary(
            today: iso(now),
            timeZone: calendar.timeZone.identifier,
            periodDays: periodDays,
            places: Array(places),
            spending: spending,
            busy: blocks,
            planningWindowDays: planningWindowDays
        )
    }

    private func weekdayName(_ date: Date) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func roundDown(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 900).rounded(.down) * 900)
    }

    private func roundUp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 900).rounded(.up) * 900)
    }
}
