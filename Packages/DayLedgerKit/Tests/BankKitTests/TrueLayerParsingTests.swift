import XCTest
@testable import BankKit
import SharedModels

final class TrueLayerParsingTests: XCTestCase {
    func testParsesTimestampWithOffset() throws {
        let parsed = try XCTUnwrap(TrueLayerDateParser.parse("2024-03-06T09:14:00+00:00"))
        XCTAssertEqual(parsed.date, londonDate(2024, 3, 6, 9, 14))
        XCTAssertTrue(parsed.hasTime)
    }

    func testParsesLongFractionalSeconds() throws {
        let parsed = try XCTUnwrap(TrueLayerDateParser.parse("2024-07-01T12:30:15.1234567Z"))
        // 12:30 UTC is 13:30 in London during BST.
        XCTAssertEqual(Calendar.london.component(.hour, from: parsed.date), 13)
        XCTAssertTrue(parsed.hasTime)
    }

    func testMidnightWithoutOffsetIsDateOnlyInLondon() throws {
        let parsed = try XCTUnwrap(TrueLayerDateParser.parse("2024-07-06T00:00:00"))
        XCTAssertFalse(parsed.hasTime)
        XCTAssertEqual(parsed.date, londonDate(2024, 7, 6))
    }

    func testMidnightWithOffsetIsDateOnly() throws {
        let parsed = try XCTUnwrap(TrueLayerDateParser.parse("2024-07-06T00:00:00+00:00"))
        XCTAssertFalse(parsed.hasTime)
        XCTAssertTrue(Calendar.london.isDate(parsed.date, inSameDayAs: londonDate(2024, 7, 6, 12)))
    }

    func testRejectsGarbage() {
        XCTAssertNil(TrueLayerDateParser.parse("yesterday"))
    }

    func testDecodesAndMapsTransactions() throws {
        let json = """
        {"results":[
          {"transaction_id":"abc","timestamp":"2024-03-06T09:14:00+00:00","description":"SQ *COSTA COFFEE 4312 LONDON GB",
           "transaction_type":"DEBIT","transaction_category":"PURCHASE","transaction_classification":["Food & Dining","Coffee shops"],
           "amount":-3.4,"currency":"GBP"},
          {"transaction_id":"def","timestamp":"2024-03-06T00:00:00","description":"SALARY ACME LTD",
           "transaction_type":"CREDIT","transaction_category":"CREDIT","transaction_classification":[],
           "amount":2150.55,"currency":"GBP"}
        ],"status":"Succeeded"}
        """
        let decoded = try JSONDecoder.trueLayer.decode(TLResults<TLTransaction>.self, from: Data(json.utf8))
        let mapped = decoded.results.compactMap { TransactionMapper.map($0, accountID: "acc1", isPending: false) }
        XCTAssertEqual(mapped.count, 2)

        let coffee = mapped[0]
        XCTAssertEqual(coffee.id, "acc1:abc")
        XCTAssertEqual(coffee.merchant, "Costa Coffee")
        XCTAssertEqual(coffee.amountMinor, 340)
        XCTAssertEqual(coffee.direction, .debit)
        XCTAssertEqual(coffee.category, .coffee)
        XCTAssertTrue(coffee.hasTime)

        let salary = mapped[1]
        XCTAssertEqual(salary.amountMinor, 215_055)
        XCTAssertEqual(salary.direction, .credit)
        XCTAssertEqual(salary.category, .income)
        XCTAssertFalse(salary.hasTime)
    }

    func testPendingTransactionsGetDistinctIDs() throws {
        let dto = TLTransaction(transactionId: "x", timestamp: "2024-03-06T10:00:00Z", description: "TESCO", transactionType: "DEBIT",
                                transactionCategory: "PURCHASE", transactionClassification: nil, merchantName: nil, amount: -5,
                                currency: "GBP", normalisedProviderTransactionId: nil, providerTransactionId: nil)
        let pending = try XCTUnwrap(TransactionMapper.map(dto, accountID: "a", isPending: true))
        let settled = try XCTUnwrap(TransactionMapper.map(dto, accountID: "a", isPending: false))
        XCTAssertNotEqual(pending.id, settled.id)
        XCTAssertTrue(pending.isPending)
    }
}
