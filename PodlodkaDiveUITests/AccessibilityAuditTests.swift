import XCTest

final class AccessibilityAuditTests: XCTestCase {
    @MainActor
    func testCaptainJournalCanBeReadAndConfigured() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["openJournal"].tap()
        app.buttons["openCaptainJournal"].tap()
        XCTAssertTrue(app.staticTexts["Вахтенный журнал"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Обновить"].exists)
        app.buttons["Совсем пьян"].tap()
        XCTAssertTrue(app.buttons["Совсем пьян"].isSelected)
        app.buttons["Трезв как стекло"].tap()
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["Готово"].tap()
        app.buttons["openCrewJournal"].tap()
        XCTAssertTrue(app.navigationBars["Бортовой журнал"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Crew audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["Готово"].tap()
        app.buttons["closeArchives"].tap()
        XCTAssertTrue(app.buttons["startDive"].exists)
    }

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
    func testReceiptAndArchivedCaseSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "completed"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["diveReceipt"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ЧЕК · ")).firstMatch.exists { app.swipeUp() }
        let expectedReceipt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ЧЕК · ")).firstMatch.label
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["openJournal"].tap()
        let bureau = app.buttons["openBureau"]
        XCTAssertTrue(bureau.waitForExistence(timeout: 5))
        for _ in 0..<4 where !bureau.isHittable { app.swipeUp() }
        bureau.tap()
        let archivedCase = app.buttons["diveCase"].firstMatch
        XCTAssertTrue(archivedCase.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        archivedCase.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diveReceipt"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ЧЕК · ")).firstMatch.exists { app.swipeUp() }
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ЧЕК · ")).firstMatch.label, expectedReceipt)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Добыча: 750")).firstMatch.exists)
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
        XCTAssertTrue(app.buttons["confirmAbandon"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["confirmAbandon"].firstMatch.tap()
        XCTAssertTrue(app.buttons["startDive"].waitForExistence(timeout: 5))
        app.buttons["openGarage"].tap()
        XCTAssertTrue(app.navigationBars["Гараж"].waitForExistence(timeout: 5))
    }
}

final class ExpeditionJournalUITests: XCTestCase {
    @MainActor
    func testJournalReplaySeekAndGraphs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "journal"]
        app.launch()
        XCTAssertTrue(app.buttons["openJournal"].waitForExistence(timeout: 10))
        app.buttons["openJournal"].tap()
        app.buttons["openTelemetry"].tap()
        XCTAssertTrue(app.buttons["expeditionRow"].firstMatch.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["expeditionRow"].firstMatch.tap()
        app.buttons["replay"].tap()
        XCTAssertTrue(app.sliders["replayTimeline"].waitForExistence(timeout: 10))
        let initialTime = app.staticTexts["replayTime"].label
        app.sliders["replayTimeline"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertNotEqual(app.staticTexts["replayTime"].label, initialTime)
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        XCTAssertTrue(app.buttons["replayHighlight"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["replayHighlight"].firstMatch.tap()
        app.buttons["replayPlay"].tap()
        XCTAssertTrue(app.buttons["Пауза"].exists)
        app.buttons["replayPlay"].tap()
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["runFlow"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Welcome → Game: 1"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["allFlows"].tap()
        XCTAssertTrue(app.staticTexts["Все экспедиции"].waitForExistence(timeout: 5))
    }
}

extension AccessibilityAuditTests {
    @MainActor
    func testJournalReplayAndFlowAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "journal"]
        app.launch()
        XCTAssertTrue(app.buttons["openJournal"].waitForExistence(timeout: 5))
        app.buttons["openJournal"].tap()
        app.buttons["openBlackBox"].tap()
        XCTAssertTrue(app.buttons["journalRun"].firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Journal audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["journalRun"].firstMatch.tap()
        XCTAssertTrue(app.sliders["replaySeek"].waitForExistence(timeout: 5))
        let initialTime = app.staticTexts["replayTime"].label
        app.sliders["replaySeek"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertNotEqual(app.staticTexts["replayTime"].label, initialTime)
        try app.performAccessibilityAudit { issue in
            print("Journal audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["blackBoxFlow"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "→ playing")).firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            print("Archive audit: \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
            return false
        }
    }
}

extension AccessibilityAuditTests {
    @MainActor
    func testCampaignSelectionLocksUnlocksAndPersists() throws {
        // given
        let app = XCUIApplication()
        app.launchArguments = ["-accessibilityAuditState", "campaignClean"]
        app.launch()
        app.buttons["openCampaign"].tap()

        // when / then: locked missions are readable, with no launch action.
        XCTAssertTrue(app.buttons["selectMission-aster"].exists)
        XCTAssertFalse(app.buttons["selectMission-currentStation"].exists)
        XCTAssertFalse(app.buttons["selectMission-silentSignal"].exists)
        try app.performAccessibilityAudit()
        app.terminate()
        app.launchArguments = ["-accessibilityAuditState", "completed"]
        app.launch()
        let next = app.buttons["nextMission"]
        for _ in 0..<5 where !next.isHittable { app.swipeUp() }
        next.tap()
        XCTAssertTrue(app.buttons["selectMission-currentStation"].waitForExistence(timeout: 5))
        let selection = app.buttons["selectMission-currentStation"]
        for _ in 0..<5 where !selection.isHittable { app.swipeUp() }
        selection.tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Оборудование уже на борту")).firstMatch.exists)
        try app.performAccessibilityAudit()
        let start = app.buttons["startDive"]
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        app.buttons["pauseDive"].tap()
        XCTAssertTrue(app.buttons["returnCourse"].exists)
        let abort = app.buttons["returnToMenu"]
        for _ in 0..<6 where !abort.isHittable { app.swipeUp() }
        abort.tap()
        XCTAssertTrue(app.buttons["cancelAbandon"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["cancelAbandon"].firstMatch.tap()
        XCTAssertTrue(app.buttons["resumeDive"].exists)
    }

    @MainActor
    func testMissionAndPartialResultAccessibility() throws {
        for state in ["station", "search", "returned"] {
            // given
            let app = XCUIApplication()
            app.launchArguments = ["-accessibilityAuditState", state]
            app.launch()

            // then
            if state == "returned" {
                XCTAssertTrue(app.descendants(matching: .any)["completedSummary"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["nextMission"].exists)
            } else {
                XCTAssertTrue(app.buttons["resumeDive"].waitForExistence(timeout: 5))
            }
            try app.performAccessibilityAudit { issue in
                print("Campaign \(state): \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
                return false
            }
            if state != "returned" {
                app.buttons["resumeDive"].tap()
                XCTAssertTrue(app.buttons["sonar"].exists)
                let specificStatus = state == "station" ? "Оборудование на борту" : "Проверено 0 из 3 сигналов"
                XCTAssertTrue(app.staticTexts[specificStatus].exists, "Fixture must show the requested mission, not Aster")
                try app.performAccessibilityAudit { issue in
                    print("Campaign HUD \(state): \(issue.compactDescription): \(issue.element?.debugDescription ?? issue.detailedDescription)")
                    return false
                }
            }
            app.terminate()
        }
    }
}
