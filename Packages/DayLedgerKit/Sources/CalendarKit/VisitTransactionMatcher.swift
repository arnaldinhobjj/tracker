import Foundation
import SharedModels

/// How sure we are that a transaction happened during a visit.
public enum MatchConfidence: String, Codable, Sendable {
    /// The merchant name matches the place name and the time fits.
    case strong
    /// No name match, but it is the only visit covering the purchase time and the purchase is
    /// the in-person kind (coffee, groceries, ...). Shown as "likely" in the calendar.
    case likely
}

public struct MatchedTransaction: Hashable, Sendable {
    public let transaction: BankTransaction
    public let confidence: MatchConfidence

    public init(transaction: BankTransaction, confidence: MatchConfidence) {
        self.transaction = transaction
        self.confidence = confidence
    }
}

/// Links bank transactions to the visits they were made at.
///
/// Rules (each transaction is attached to at most one visit):
/// 1. Only spending and refunds are considered (no transfers or income).
/// 2. Timed transactions: candidate visits are those whose window
///    `[arrival - preArrivalGrace, departure + postDepartureGrace]` contains the time.
///    Card timestamps can lag the tap by several minutes, hence the grace periods.
///    - The best name match at or above `nameThreshold` wins (ties go to the closest visit in time).
///    - Otherwise, if exactly one *named* visit strictly contains the time and the purchase is
///      typically in person, it is a `.likely` match.
/// 3. Date-only transactions (no time from the bank) match only by name, and only when exactly one
///    visit that day matches; two visits to the same chain that day are ambiguous and skipped.
public struct VisitTransactionMatcher: Sendable {
    public var preArrivalGrace: TimeInterval
    public var postDepartureGrace: TimeInterval
    public var nameThreshold: Double
    public var calendar: Calendar

    public init(preArrivalGrace: TimeInterval = 5 * 60, postDepartureGrace: TimeInterval = 20 * 60,
                nameThreshold: Double = 0.5, calendar: Calendar = .current) {
        self.preArrivalGrace = preArrivalGrace
        self.postDepartureGrace = postDepartureGrace
        self.nameThreshold = nameThreshold
        self.calendar = calendar
    }

    /// Returns matches keyed by visit ID. Visits without a departure are treated as ongoing until `now`.
    public func match(visits: [PlaceVisit], transactions: [BankTransaction], now: Date = Date()) -> [String: [MatchedTransaction]] {
        var result: [String: [MatchedTransaction]] = [:]
        let relevant = transactions.filter { SpendingCalculator.isSpend($0) || SpendingCalculator.isRefund($0) }

        for transaction in relevant.sorted(by: { $0.timestamp < $1.timestamp }) {
            let match = transaction.hasTime
                ? matchTimed(transaction, visits: visits, now: now)
                : matchDateOnly(transaction, visits: visits)
            if let (visitID, confidence) = match {
                result[visitID, default: []].append(MatchedTransaction(transaction: transaction, confidence: confidence))
            }
        }
        return result
    }

    private func nameScore(_ transaction: BankTransaction, _ visit: PlaceVisit) -> Double {
        guard let place = visit.placeName else { return 0 }
        return max(
            MerchantNameNormaliser.similarity(transaction.merchant, place),
            MerchantNameNormaliser.similarity(transaction.rawDescription, place)
        )
    }

    private func matchTimed(_ transaction: BankTransaction, visits: [PlaceVisit], now: Date) -> (String, MatchConfidence)? {
        let time = transaction.timestamp
        let candidates = visits.filter { visit in
            let end = visit.departure ?? now
            return time >= visit.arrival.addingTimeInterval(-preArrivalGrace)
                && time <= end.addingTimeInterval(postDepartureGrace)
        }
        guard !candidates.isEmpty else { return nil }

        func timeDistance(_ visit: PlaceVisit) -> TimeInterval {
            let end = visit.departure ?? now
            if time < visit.arrival { return visit.arrival.timeIntervalSince(time) }
            if time > end { return time.timeIntervalSince(end) }
            return 0
        }

        let named = candidates
            .map { ($0, nameScore(transaction, $0)) }
            .filter { $0.1 >= nameThreshold }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : timeDistance(lhs.0) < timeDistance(rhs.0)
            }
        if let best = named.first {
            return (best.0.id, .strong)
        }

        guard transaction.category.isTypicallyInPerson else { return nil }
        let containing = candidates.filter { visit in
            visit.isNamedPlace && time >= visit.arrival && time <= (visit.departure ?? now)
        }
        if containing.count == 1, let only = containing.first {
            return (only.id, .likely)
        }
        return nil
    }

    private func matchDateOnly(_ transaction: BankTransaction, visits: [PlaceVisit]) -> (String, MatchConfidence)? {
        let sameDay = visits.filter {
            calendar.isDate($0.arrival, inSameDayAs: transaction.timestamp) && nameScore(transaction, $0) >= nameThreshold
        }
        guard sameDay.count == 1, let only = sameDay.first else { return nil }
        return (only.id, .strong)
    }
}
