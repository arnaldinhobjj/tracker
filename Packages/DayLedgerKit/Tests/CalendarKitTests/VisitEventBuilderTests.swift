import XCTest
@testable import CalendarKit
import SharedModels

final class VisitEventBuilderTests: XCTestCase {
    let builder = VisitEventBuilder(timeZone: TimeZone(identifier: "Europe/London")!)

    private let visit = PlaceVisit(id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                                   arrival: londonDate(2024, 3, 6, 9, 10), departure: londonDate(2024, 3, 6, 9, 45),
                                   latitude: 51.5, longitude: -0.12, placeName: "Costa Coffee",
                                   placeCategory: "MKPOICategoryCafe", isNamedPlace: true)

    private func coffee(_ pence: Int, likely: Bool = false) -> MatchedTransaction {
        MatchedTransaction(transaction: BankTransaction(id: "t\(pence)", accountID: "a", merchant: "Costa Coffee", rawDescription: "COSTA",
                                                        amountMinor: pence, direction: .debit, bankCategory: "PURCHASE", category: .coffee,
                                                        timestamp: londonDate(2024, 3, 6, 9, 14), hasTime: true, isPending: false),
                           confidence: likely ? .likely : .strong)
    }

    func testBuildsEventWithSpend() throws {
        let draft = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(340)]))
        XCTAssertEqual(draft.summary, "At Costa Coffee · £3.40")
        XCTAssertEqual(draft.start, visit.arrival)
        XCTAssertEqual(draft.end, visit.departure)
        XCTAssertTrue(draft.description.hasPrefix("09:10–09:45 at Costa Coffee (Cafe)"))
        XCTAssertTrue(draft.description.contains("Spent £3.40 at Costa Coffee (09:14)"))
        XCTAssertFalse(draft.showsAsBusy)
        XCTAssertEqual(draft.privateProperties["dayledgerVisitID"], visit.id)
    }

    func testVisitWithoutSpendHasPlainTitle() throws {
        let draft = try XCTUnwrap(builder.draft(for: visit, matches: []))
        XCTAssertEqual(draft.summary, "At Costa Coffee")
    }

    func testLikelyMatchIsLabelled() throws {
        let draft = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(280, likely: true)]))
        XCTAssertTrue(draft.description.contains("likely match"))
    }

    func testOngoingVisitIsNotWritten() {
        var ongoing = visit
        ongoing.departure = nil
        XCTAssertNil(builder.draft(for: ongoing, matches: []))
    }

    func testEventIDIsDeterministicAndValid() throws {
        let first = try XCTUnwrap(builder.draft(for: visit, matches: []))
        let second = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(340)]))
        XCTAssertEqual(first.id, second.id, "Same visit -> same event, so re-syncing updates instead of duplicating")
        XCTAssertTrue(CalendarEventID.isValid(first.id))
        XCTAssertTrue(CalendarEventID.isValid(CalendarEventID.forVisit("weird/id with spaces & xyz")))
        XCTAssertNotEqual(CalendarEventID.forVisit("visit-wxyz-1"), CalendarEventID.forVisit("visit-wxyz-2"))
    }

    func testContentHashChangesOnlyWhenContentChanges() throws {
        let a = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(340)]))
        let b = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(340)]))
        let c = try XCTUnwrap(builder.draft(for: visit, matches: [coffee(340), coffee(250)]))
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertNotEqual(a.contentHash, c.contentHash)
    }
}
