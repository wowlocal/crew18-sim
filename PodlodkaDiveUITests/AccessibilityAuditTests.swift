import XCTest

final class AccessibilityAuditTests: XCTestCase {
    @MainActor
    func testAccessibilityAuditOnEveryScreen() throws {
        for (state, control) in [("ready", "startDive"), ("playing", "pauseDive"),
                                  ("paused", "resumeDive"), ("map", "closeMap"),
                                  ("completed", "retryDive"), ("gameOver", "retryDive")] {
            // given
            let app = XCUIApplication()
            app.launchArguments = ["-accessibilityAuditState", state]

            // when
            app.launch()

            // then: prove the fixture reached its screen before auditing it.
            XCTAssertTrue(app.buttons[control].waitForExistence(timeout: 5), "Missing control in \(state)")
            if state != "ready" { XCTAssertFalse(app.buttons["startDive"].exists) }
            if state == "completed" || state == "gameOver" {
                XCTAssertTrue(app.descendants(matching: .any)[state + "Summary"].exists)
            }
            try app.performAccessibilityAudit { issue in
                print("Audit \(state): \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
                if issue.element == nil { print(app.debugDescription) }
                return false
            }
            app.terminate()
        }
    }

    @MainActor
    func testReceiptAndArchivedCaseSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "completed"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["diveReceipt"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        let bureau = app.buttons["openBureau"]
        XCTAssertTrue(bureau.waitForExistence(timeout: 5))
        for _ in 0..<4 where !bureau.isHittable { app.swipeUp() }
        bureau.tap()
        let archivedCase = app.buttons["diveCase"].firstMatch
        XCTAssertTrue(archivedCase.waitForExistence(timeout: 5))
        archivedCase.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diveReceipt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Чёрный ящик доставлен. Добыча: 750"].firstMatch.exists)
    }

    @MainActor
    func testMenuGameMapPauseAndGarageNavigation() {
        // given
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["startDive"].waitForExistence(timeout: 5))

        // when / then
        app.buttons["startDive"].tap()
        XCTAssertTrue(app.buttons["pauseDive"].waitForExistence(timeout: 5))
        app.buttons["openMap"].tap()
        XCTAssertTrue(app.buttons["closeMap"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sonar"].exists)
        app.buttons["closeMap"].tap()
        app.buttons["pauseDive"].tap()
        XCTAssertTrue(app.buttons["resumeDive"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["boost"].exists)
        app.buttons["returnToMenu"].tap()
        XCTAssertTrue(app.buttons["startDive"].waitForExistence(timeout: 5))
        app.buttons["openGarage"].tap()
        XCTAssertTrue(app.navigationBars["Гараж"].waitForExistence(timeout: 5))
    }
}
