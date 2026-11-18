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
        let privacyLink = app.buttons["Privacy & your data"]
        scroll(app, until: privacyLink)
        privacyLink.tap()
        XCTAssertTrue(app.navigationBars["Privacy & your data"].waitForExistence(timeout: 5))

        // The delete button is at the bottom of a long list; scroll until it is rendered.
        let deleteButton = app.buttons["deleteAllData"]
        scroll(app, until: deleteButton)
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

    @MainActor
    func testSuggestTabIsOptInByDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()

        app.tabBars.buttons["Suggest"].tap()
        XCTAssertTrue(app.staticTexts["AI assistant is off"].waitForExistence(timeout: 5))
    }

    /// Lists render lazily, so off-screen rows don't exist until scrolled to (small simulators).
    private func scroll(_ app: XCUIApplication, until element: XCUIElement, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }
}
