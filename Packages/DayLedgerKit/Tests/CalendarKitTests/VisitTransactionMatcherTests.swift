import XCTest
import CalendarKit
import SharedModels

/// Transaction-to-visit matching: the rules that decide which purchase gets attached to
/// which calendar entry.
final class VisitTransactionMatcherTests: XCTestCase {
    let matcher = VisitTransactionMatcher(calendar: .london)

    private func visit(_ id: String, _ name: String?, from: (Int, Int), to: (Int, Int)?, day: Int = 6, named: Bool = true) -> PlaceVisit {
        PlaceVisit(id: id,
                   arrival: londonDate(2024, 3, day, from.0, from.1),
                   departure: to.map { londonDate(2024, 3, day, $0.0, $0.1) },
                   latitude: 51.5, longitude: -0.12, placeName: name, isNamedPlace: named)
    }

    private func tx(_ id: String, _ merchant: String, _ pence: Int, at: (Int, Int), day: Int = 6, category: SpendCategory = .coffee,
                    direction: TransactionDirection = .debit, bankCategory: String = "PURCHASE", hasTime: Bool = true) -> BankTransaction {
        BankTransaction(id: id, accountID: "a", merchant: merchant, rawDescription: merchant.uppercased(), amountMinor: pence,
                        direction: direction, bankCategory: bankCategory, category: category,
                        timestamp: hasTime ? londonDate(2024, 3, day, at.0, at.1) : londonDate(2024, 3, day),
                        hasTime: hasTime, isPending: false)
    }

    func testMatchesByNameInsideVisit() {
        let visits = [visit("costa", "Costa Coffee", from: (9, 10), to: (9, 45))]
        let result = matcher.match(visits: visits, transactions: [tx("t1", "COSTA COFFEE 4312", 340, at: (9, 14))])
        XCTAssertEqual(result["costa"]?.map(\.transaction.id), ["t1"])
        XCTAssertEqual(result["costa"]?.first?.confidence, .strong)
    }

    func testCardTimestampAfterLeavingStillMatchesByName() {
        let visits = [visit("costa", "Costa Coffee", from: (9, 10), to: (9, 45))]
        // Cleared 15 minutes after leaving: within the post-departure grace period.
        let result = matcher.match(visits: visits, transactions: [tx("t1", "Costa Coffee", 340, at: (10, 0))])
        XCTAssertEqual(result["costa"]?.first?.confidence, .strong)
    }

    func testTooLateIsNotMatched() {
        let visits = [visit("costa", "Costa Coffee", from: (9, 10), to: (9, 45))]
        let result = matcher.match(visits: visits, transactions: [tx("t1", "Costa Coffee", 340, at: (11, 0))])
        XCTAssertTrue(result.isEmpty)
    }

    func testTimeOnlyMatchIsLikelyForInPersonPurchase() {
        // Independent café whose card descriptor doesn't resemble its map name.
        let visits = [visit("cafe", "The Bean Counter", from: (9, 0), to: (9, 30))]
        let result = matcher.match(visits: visits, transactions: [tx("t1", "SumUp Jb Ltd", 280, at: (9, 12), category: .coffee)])
        XCTAssertEqual(result["cafe"]?.first?.confidence, .likely)
    }

    func testSubscriptionDuringVisitIsNotMatched() {
        let visits = [visit("cafe", "The Bean Counter", from: (9, 0), to: (9, 30))]
        let netflix = tx("t1", "Netflix", 1_099, at: (9, 5), category: .entertainment)
        let bill = tx("t2", "Octopus Energy", 8_000, at: (9, 6), category: .bills, bankCategory: "DIRECT_DEBIT")
        XCTAssertTrue(matcher.match(visits: visits, transactions: [netflix, bill]).isEmpty)
    }

    func testTimeOnlyMatchRequiresNamedPlace() {
        // An address-only visit (e.g. a friend's house) shouldn't absorb unrelated card spend.
        let visits = [visit("addr", "12 Acacia Avenue", from: (9, 0), to: (10, 0), named: false)]
        XCTAssertTrue(matcher.match(visits: visits, transactions: [tx("t1", "Joe's", 500, at: (9, 30), category: .coffee)]).isEmpty)
    }

    func testAmbiguousTimeOnlyMatchIsSkipped() {
        // Two overlapping named visits (e.g. a shopping centre) and no name match: don't guess.
        let visits = [
            visit("a", "Boots", from: (14, 0), to: (14, 40)),
            visit("b", "Westfield", from: (13, 30), to: (15, 0)),
        ]
        XCTAssertTrue(matcher.match(visits: visits, transactions: [tx("t1", "Card Shop", 500, at: (14, 10), category: .shopping)]).isEmpty)
    }

    func testNameDecidesBetweenAdjacentVisits() {
        // Left Pret at 12:30, arrived at Tesco at 12:35; Pret's card charge landed at 12:36.
        let visits = [
            visit("pret", "Pret A Manger", from: (12, 0), to: (12, 30)),
            visit("tesco", "Tesco Express", from: (12, 35), to: (12, 50)),
        ]
        let transactions = [
            tx("pret-charge", "PRET A MANGER", 645, at: (12, 36), category: .eatingOut),
            tx("tesco-charge", "TESCO STORES 3412", 1_287, at: (12, 48), category: .groceries),
        ]
        let result = matcher.match(visits: visits, transactions: transactions)
        XCTAssertEqual(result["pret"]?.map(\.transaction.id), ["pret-charge"])
        XCTAssertEqual(result["tesco"]?.map(\.transaction.id), ["tesco-charge"])
    }

    func testDateOnlyTransactionMatchesUniqueNamedVisitThatDay() {
        let visits = [visit("gym", "PureGym", from: (7, 0), to: (8, 0))]
        let result = matcher.match(visits: visits, transactions: [tx("t1", "PureGym", 2_499, at: (0, 0), category: .health, hasTime: false)])
        XCTAssertEqual(result["gym"]?.first?.confidence, .strong)
    }

    func testDateOnlyTransactionWithTwoSameNameVisitsIsAmbiguous() {
        let visits = [
            visit("am", "Costa Coffee", from: (9, 0), to: (9, 20)),
            visit("pm", "Costa Coffee", from: (15, 0), to: (15, 20)),
        ]
        XCTAssertTrue(matcher.match(visits: visits, transactions: [tx("t1", "Costa", 340, at: (0, 0), hasTime: false)]).isEmpty)
    }

    func testTransfersAndIncomeAreIgnored() {
        let visits = [visit("bank", "Barclays", from: (11, 0), to: (11, 30))]
        let transfer = tx("t1", "Barclays", 10_000, at: (11, 10), category: .transfer, bankCategory: "TRANSFER")
        let salary = tx("t2", "Barclays", 200_000, at: (11, 15), category: .income, direction: .credit, bankCategory: "CREDIT")
        XCTAssertTrue(matcher.match(visits: visits, transactions: [transfer, salary]).isEmpty)
    }

    func testRefundsAreMatchedByName() {
        let visits = [visit("boots", "Boots", from: (16, 0), to: (16, 20))]
        let refund = tx("r1", "Boots", 499, at: (16, 5), category: .health, direction: .credit)
        XCTAssertEqual(matcher.match(visits: visits, transactions: [refund])["boots"]?.count, 1)
    }

    func testOngoingVisitUsesNowAsEnd() {
        let visits = [visit("costa", "Costa Coffee", from: (9, 0), to: nil)]
        let now = londonDate(2024, 3, 6, 9, 30)
        let result = matcher.match(visits: visits, transactions: [tx("t1", "Costa Coffee", 340, at: (9, 20))], now: now)
        XCTAssertEqual(result["costa"]?.count, 1)
    }

    func testEachTransactionIsAttachedToOneVisitOnly() {
        // Back-to-back visits to the same chain: the charge goes to the one it falls inside.
        let visits = [
            visit("v1", "Costa Coffee", from: (9, 0), to: (9, 20)),
            visit("v2", "Costa Coffee", from: (9, 25), to: (9, 50)),
        ]
        let result = matcher.match(visits: visits, transactions: [tx("t1", "Costa Coffee", 340, at: (9, 30))])
        XCTAssertEqual(result.values.flatMap { $0 }.count, 1)
        XCTAssertEqual(result["v2"]?.count, 1)
    }
}
