import CoreGraphics
import XCTest

@testable import PodlodkaDive

@MainActor
enum GameTestPilot {
  static func advance(_ engine: GameEngine, _ seconds: Double, fps: Double = 120) {
    for _ in 0..<Int((seconds * fps).rounded()) { engine.step(deltaTime: 1 / fps) }
  }

  static func navigate(_ engine: GameEngine, through points: [CGPoint], fps: Double = 120) {
    let initialZone = engine.zone
    for target in points {
      for _ in 0..<700 {
        guard engine.state == .playing, engine.zone == initialZone else { return }
        let dx = target.x - engine.position.x
        let dy = target.y - engine.position.y
        if hypot(dx, dy) < 8 { break }
        let distance = hypot(dx, dy)
        let speed = min(GameEngine.cruiseSpeed, distance * 2.8)
        let flow = engine.current(at: engine.position)
        engine.setSteering(
          CGVector(
            dx: (dx / distance * speed - flow.dx) / GameEngine.cruiseSpeed,
            dy: (dy / distance * speed - flow.dy) / GameEngine.cruiseSpeed))
        advance(engine, 0.1, fps: fps)
      }
      XCTAssertLessThan(
        hypot(target.x - engine.position.x, target.y - engine.position.y), 10,
        "Unreachable waypoint \(target), position \(engine.position), energy \(engine.energy)")
    }
    engine.setSteering(.zero)
    advance(engine, 0.5, fps: fps)
  }

  static func surviveCave(_ engine: GameEngine) -> Bool {
    var sawWarning = false
    for _ in 0..<300 where engine.zone == .bossCave && engine.state == .playing {
      if let strike = engine.bossStrike, strike.phase == .warning {
        sawWarning = true
        let goRight =
          strike.position.x < GameEngine.caveSize.width / 2
          || engine.position.x < GameEngine.caveSize.width / 2
        engine.setSteering(CGVector(dx: goRight ? 1 : -1, dy: 0))
        engine.activateBoost()
      } else if engine.bossStrike?.phase == .impact {
        engine.setSteering(.zero)
      }
      advance(engine, 0.1)
    }
    return sawWarning
  }
}
