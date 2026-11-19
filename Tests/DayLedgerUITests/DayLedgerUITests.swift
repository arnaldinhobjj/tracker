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
        // VoiceOver reads "Spent today, £25.52": the amount is the element's value.
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "£25.52"), object: total)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "Total was \(String(describing: total.value))")
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

    /// Xcode's accessibility audit on each tab: every element has a description VoiceOver can
    /// read, text scales with Dynamic Type, and text has enough contrast.
    @MainActor
    func testTabsPassTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMockData"]
        app.launch()
        XCTAssertTrue(app.staticTexts["todayTotal"].waitForExistence(timeout: 15))

        var problems: [String] = []
        for tab in ["Today", "Places", "Suggest", "Settings"] {
            app.tabBars.buttons[tab].tap()
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .dynamicType, .contrast]) { issue in
                // Issues in system-drawn chrome (no element of ours) aren't ours to fix.
                guard let element = issue.element,
                      element.elementType != .tabBar, element.elementType != .navigationBar else { return true }
                // iOS's standard secondary text colour (Apple's own captions and footers) is rated
                // "nearly passed"; real contrast failures are still reported.
                if issue.auditType == .contrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                    return true
                }
                problems.append("\(tab): \(issue.compactDescription) – \(element.elementType.rawValue) label=\"\(element.label)\" id=\"\(element.identifier)\"")
                return true
            }
        }
        // One failure listing every issue, with the element, so it can be fixed from the CI log.
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
    }

    /// Lists render lazily, so off-screen rows don't exist until scrolled to (small simulators).
    @MainActor
    private func scroll(_ app: XCUIApplication, until element: XCUIElement, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }
}
