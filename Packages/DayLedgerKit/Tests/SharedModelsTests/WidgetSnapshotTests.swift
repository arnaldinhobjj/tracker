import XCTest
import SharedModels

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func tx(_ id: String, _ pence: Int, _ at: Date, direction: TransactionDirection = .debit) -> BankTransaction {
        BankTransaction(id: id, accountID: "a", merchant: "M\(id)", rawDescription: "M", amountMinor: pence, direction: direction,
                        bankCategory: "PURCHASE", category: .shopping, timestamp: at, hasTime: true, isPending: false)
    }

    func testSnapshotKeepsLatestThreeAndTodaysTotal() {
        let transactions = [
            tx("1", 100, date(6, 8)), tx("2", 200, date(6, 9)), tx("3", 300, date(6, 10)),
            tx("4", 400, date(6, 11)), tx("old", 9_999, date(5, 23)),
        ]
        let snapshot = WidgetSnapshot.make(from: transactions, now: date(6, 12), calendar: calendar, hasBankConnection: true, needsReconnect: false)
        XCTAssertEqual(snapshot.totalSpentMinor, 1_000)
        XCTAssertEqual(snapshot.transactionCount, 4)
        XCTAssertEqual(snapshot.latest.map(\.id), ["4", "3", "2"])
    }

    func testStaleSnapshotShowsEmptyDayAfterMidnight() {
        let snapshot = WidgetSnapshot.make(from: [tx("1", 500, date(6, 9))], now: date(6, 12), calendar: calendar, hasBankConnection: true, needsReconnect: false)
        XCTAssertEqual(snapshot.displayed(at: date(6, 23, 59), calendar: calendar).totalSpentMinor, 500)
        let tomorrow = snapshot.displayed(at: date(7, 0, 1), calendar: calendar)
        XCTAssertEqual(tomorrow.totalSpentMinor, 0)
        XCTAssertTrue(tomorrow.latest.isEmpty)
    }

    func testContentComparisonIgnoresGenerationTime() {
        let a = WidgetSnapshot.make(from: [tx("1", 500, date(6, 9))], now: date(6, 12), calendar: calendar, hasBankConnection: true, needsReconnect: false)
        var b = a
        b.generatedAt = date(6, 13)
        XCTAssertTrue(a.hasSameContent(as: b))
        b.totalSpentMinor = 1
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        let store = WidgetSnapshotStore(fileURL: url)
        XCTAssertNil(store.load())
        try store.save(.placeholder)
        XCTAssertEqual(store.load()?.totalSpentMinor, WidgetSnapshot.placeholder.totalSpentMinor)
        store.delete()
        XCTAssertNil(store.load())
    }
}
