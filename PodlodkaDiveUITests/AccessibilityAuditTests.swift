import XCTest

final class AccessibilityAuditTests: XCTestCase {
    @MainActor
    func testAccessibilityAuditOnEveryScreen() throws {
        for state in [nil, "playing", "paused", "map", "completed", "gameOver"] {
            let app = XCUIApplication()
            if let state {
                app.launchArguments += ["-accessibilityAuditState", state]
            }
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Could not launch state: \(state ?? "welcome")")
            try app.performAccessibilityAudit()
            app.terminate()
        }
    }
}
