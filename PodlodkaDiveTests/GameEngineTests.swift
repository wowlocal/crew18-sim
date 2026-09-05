import XCTest
@testable import PodlodkaDive

@MainActor
final class GameEngineTests: XCTestCase {
    private func makeEngine() -> GameEngine {
        let defaults = UserDefaults(suiteName: "GameEngineTests")!
        defaults.removePersistentDomain(forName: "GameEngineTests")
        let engine = GameEngine(defaults: defaults)
        engine.resize(to: CGSize(width: 390, height: 844))
        return engine
    }

    func testStartingGameCreatesFirstGate() {
        let engine = makeEngine()
        engine.startGame()

        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.score, 0)
        XCTAssertEqual(engine.reefs.count, 1)
        XCTAssertGreaterThan(engine.reefs[0].x, 390)
    }

    func testHoldingThrustMovesSubmarineUp() {
        let engine = makeEngine()
        engine.startGame()
        let initialY = engine.submarineY
        engine.setThrusting(true)

        for _ in 0..<20 {
            engine.step(deltaTime: 1.0 / 60.0)
        }

        XCTAssertLessThan(engine.submarineY, initialY)
        XCTAssertLessThan(engine.submarineVelocity, 0)
    }

    func testReleasingThrustEventuallySinksSubmarine() {
        let engine = makeEngine()
        engine.startGame()
        engine.setThrusting(false)
        let initialY = engine.submarineY

        for _ in 0..<30 {
            engine.step(deltaTime: 1.0 / 60.0)
        }

        XCTAssertGreaterThan(engine.submarineY, initialY)
        XCTAssertGreaterThan(engine.submarineVelocity, 0)
    }

    func testPauseFreezesSimulation() {
        let engine = makeEngine()
        engine.startGame()
        engine.togglePause()
        let y = engine.submarineY
        let gateX = engine.reefs[0].x

        engine.step(deltaTime: 1)

        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.submarineY, y)
        XCTAssertEqual(engine.reefs[0].x, gateX)
    }
}
