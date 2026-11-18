import XCTest
@testable import BankKit
import SharedModels

final class CategorisationAndSpendingTests: XCTestCase {
    func testMerchantBeatsGenericClassification() {
        let category = TransactionCategoriser.categorise(bankCategory: "PURCHASE", classification: ["Food & Dining"], merchant: "Costa Coffee", direction: .debit)
        XCTAssertEqual(category, .coffee)
    }

    func testClassificationUsedForUnknownMerchant() {
        let category = TransactionCategoriser.categorise(bankCategory: "PURCHASE", classification: ["Shopping", "Groceries"], merchant: "Joe's Corner Shop", direction: .debit)
        XCTAssertEqual(category, .groceries)
    }

    func testTransfersAndCash() {
        XCTAssertEqual(TransactionCategoriser.categorise(bankCategory: "TRANSFER", classification: [], merchant: "J Smith", direction: .debit), .transfer)
        XCTAssertEqual(TransactionCategoriser.categorise(bankCategory: "ATM", classification: [], merchant: "Link ATM", direction: .debit), .cash)
        XCTAssertEqual(TransactionCategoriser.categorise(bankCategory: "DIRECT_DEBIT", classification: [], merchant: "Unknown Ltd", direction: .debit), .bills)
    }

    func testRefundKeepsPurchaseCategory() {
        XCTAssertEqual(TransactionCategoriser.categorise(bankCategory: "PURCHASE", classification: [], merchant: "Amazon", direction: .credit), .shopping)
    }

    func testNetSpendSubtractsRefundsAndIgnoresTransfersAndIncome() {
        let day = londonDate(2024, 3, 6, 12)
        func tx(_ pence: Int, _ direction: TransactionDirection, _ bank: String, _ category: SpendCategory, hour: Int = 10, dayOffset: Int = 0) -> BankTransaction {
            BankTransaction(id: UUID().uuidString, accountID: "a", merchant: "m", rawDescription: "m", amountMinor: pence,
                            direction: direction, bankCategory: bank, category: category,
                            timestamp: londonDate(2024, 3, 6 + dayOffset, hour), hasTime: true, isPending: false)
        }
        let transactions = [
            tx(340, .debit, "PURCHASE", .coffee),
            tx(1_000, .debit, "PURCHASE", .shopping),
            tx(250, .credit, "PURCHASE", .shopping),       // refund
            tx(50_000, .debit, "TRANSFER", .transfer),     // to savings
            tx(200_000, .credit, "CREDIT", .income),       // salary
            tx(999, .debit, "PURCHASE", .other, dayOffset: -1), // yesterday
        ]
        XCTAssertEqual(SpendingCalculator.netSpendMinor(transactions, on: day, calendar: .london), 1_090)
    }

    func testMoneyConversionAvoidsFloatingPointErrors() {
        XCTAssertEqual(MoneyFormatting.minorUnits(fromMajor: -3.4), 340)
        XCTAssertEqual(MoneyFormatting.minorUnits(fromMajor: 0.1 + 0.2), 30)
        XCTAssertEqual(MoneyFormatting.minorUnits(fromMajor: 1234.56), 123_456)
        XCTAssertEqual(MoneyFormatting.string(minorUnits: 340), "£3.40")
    }

    func testMerchantNormaliser() {
        XCTAssertEqual(MerchantNameNormaliser.displayName(from: "SQ *JOE'S COFFEE 1234 LONDON GB"), "Joe's Coffee")
        XCTAssertEqual(MerchantNameNormaliser.displayName(from: "TESCO STORES 3412 ON 12 MAR"), "Tesco Stores")
        XCTAssertGreaterThanOrEqual(MerchantNameNormaliser.similarity("COSTA COFFEE 4312", "Costa Coffee"), 0.99)
        XCTAssertGreaterThanOrEqual(MerchantNameNormaliser.similarity("SAINSBURYS S/MKTS", "Sainsbury's Local"), 0.5)
        XCTAssertEqual(MerchantNameNormaliser.similarity("Pret A Manger", "Costa Coffee"), 0)
    }
}
