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
        XCTAssertTrue(app.navigationBars["Privacy & your data"].waitForExistence(timeout: 5))

        // The delete button is at the bottom of a long list; scroll until it is rendered.
        let deleteButton = app.buttons["deleteAllData"]
        for _ in 0..<8 where !deleteButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlacesTabExplainsLocationIsOff() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()

        app.tabBars.buttons["Places"].tap()
        XCTAssertTrue(app.staticTexts["Location logging is off"].waitForExistence(timeout: 5))
    }
}
