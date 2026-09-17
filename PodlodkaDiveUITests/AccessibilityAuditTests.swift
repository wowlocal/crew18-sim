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

final class ExpeditionJournalUITests: XCTestCase {
    @MainActor
    func testJournalReplaySeekAndGraphs() {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "journal"]
        app.launch()
        XCTAssertTrue(app.buttons["openJournal"].waitForExistence(timeout: 10))
        app.buttons["openJournal"].tap()
        XCTAssertTrue(app.buttons["expeditionRow"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["expeditionRow"].firstMatch.tap()
        app.buttons["replay"].tap()
        XCTAssertTrue(app.sliders["replayTimeline"].waitForExistence(timeout: 10))
        app.sliders["replayTimeline"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["replayTime"].exists)
        XCTAssertTrue(app.buttons["replayHighlight"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["replayHighlight"].firstMatch.tap()
        app.buttons["replayPlay"].tap()
        XCTAssertTrue(app.buttons["Пауза"].exists)
        app.buttons["replayPlay"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["runFlow"].tap()
        XCTAssertTrue(app.staticTexts["Welcome → Game: 1"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["allFlows"].tap()
        XCTAssertTrue(app.staticTexts["Все экспедиции"].waitForExistence(timeout: 5))
    }
}

extension AccessibilityAuditTests {
    @MainActor
    func testJournalReplayAndFlowAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "completed"]
        app.launch()
        XCTAssertTrue(app.buttons["openJournal"].waitForExistence(timeout: 5))
        app.buttons["openJournal"].tap()
        XCTAssertTrue(app.buttons["journalRun"].firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Journal audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["journalRun"].firstMatch.tap()
        XCTAssertTrue(app.sliders["replaySeek"].waitForExistence(timeout: 5))
        app.sliders["replaySeek"].adjust(toNormalizedSliderPosition: 0.5)
        try app.performAccessibilityAudit { issue in
            print("Journal audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
    }
}
