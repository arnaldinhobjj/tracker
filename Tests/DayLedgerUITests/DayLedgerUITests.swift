import XCTest

/// Launches the real app with mock data to prove it starts and renders the Today screen.
final class DayLedgerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTodayScreenShowsMockSpending() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()

        let total = app.staticTexts["todayTotal"]
        XCTAssertTrue(total.waitForExistence(timeout: 15))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "£25.52"), object: total)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "Total was \(total.label)")
        XCTAssertTrue(app.descendants(matching: .any)["transactionRow"].firstMatch.exists)
    }

    @MainActor
    func testPrivacyScreenIsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        app.buttons["Privacy & your data"].tap()
        XCTAssertTrue(app.buttons["deleteAllData"].waitForExistence(timeout: 5))
    }
}
