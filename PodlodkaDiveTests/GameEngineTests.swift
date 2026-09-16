import XCTest
import Combine
import SwiftUI
@testable import PodlodkaDive

@MainActor
final class GameEngineTests: XCTestCase {
    private var empty: OceanLevel {
        OceanLevel(size: CGSize(width: 1560, height: 2600), spawn: CGPoint(x: 300, y: 300),
                   base: CGPoint(x: 180, y: 200), wreck: CGPoint(x: 1370, y: 2330))
    }

    private func makeEngine(level: OceanLevel? = nil, size: CGSize = CGSize(width: 390, height: 844),
                            defaults: UserDefaults? = nil, randomValues: [Double] = [1]) -> GameEngine {
        let suite = "ExpeditionTests.\(UUID().uuidString)"
        let storage = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil { addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
        var values = randomValues
        let engine = GameEngine(defaults: storage, level: level ?? empty,
                                randomValue: { values.isEmpty ? 1 : values.removeFirst() })
        engine.resize(to: size)
        engine.startGame()
        return engine
    }

    private func advance(_ engine: GameEngine, _ seconds: Double, fps: Double = 120) {
        for _ in 0..<Int((seconds * fps).rounded()) { engine.step(deltaTime: 1 / fps) }
    }

    private func attachResultScreen(_ engine: GameEngine, name: String, size: CGSize) {
        engine.resize(to: size)
        let renderer = ImageRenderer(content: GameView(engine: engine).frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.uiImage else { XCTFail("Could not render result screen"); return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Route follower uses the same stick as the player at 10 Hz, including
    /// counter-steering against visible currents. No position/energy overrides.
    private func navigate(_ engine: GameEngine, through points: [CGPoint], fps: Double = 120) {
        for target in points {
            for _ in 0..<700 {
                guard engine.state == .playing else { return }
                let dx = target.x - engine.position.x, dy = target.y - engine.position.y
                if hypot(dx, dy) < 8 { break }
                let distance = hypot(dx, dy)
                let speed = min(GameEngine.cruiseSpeed, distance * 2.8)
                let flow = engine.current(at: engine.position)
                engine.setSteering(CGVector(dx: (dx / distance * speed - flow.dx) / GameEngine.cruiseSpeed,
                                             dy: (dy / distance * speed - flow.dy) / GameEngine.cruiseSpeed))
                advance(engine, 0.1, fps: fps)
            }
            XCTAssertLessThan(hypot(target.x - engine.position.x, target.y - engine.position.y), 10,
                              "Unreachable waypoint \(target), position \(engine.position), energy \(engine.energy)")
        }
        engine.setSteering(.zero)
        advance(engine, 0.5, fps: fps)
    }

    func testAccessibilityClockBearingUsesScreenClockFace() {
        let origin = CGPoint(x: 100, y: 100)
        XCTAssertEqual(AccessibilityNavigation.clockHour(from: origin, to: CGPoint(x: 100, y: 0)), 12)
        XCTAssertEqual(AccessibilityNavigation.clockHour(from: origin, to: CGPoint(x: 200, y: 100)), 3)
        XCTAssertEqual(AccessibilityNavigation.clockHour(from: origin, to: CGPoint(x: 100, y: 200)), 6)
        XCTAssertEqual(AccessibilityNavigation.clockHour(from: origin, to: CGPoint(x: 0, y: 100)), 9)
        XCTAssertEqual(AccessibilityNavigation.clockHour(from: origin, to: CGPoint(x: 200, y: 0)), 2)
        XCTAssertEqual(AccessibilityNavigation.distanceMeters(from: origin, to: CGPoint(x: 400, y: 500)), 80)
    }

    func testSonarContactsIncludeRequiredObjectsAndRespectVisibilityAndRange() {
        var level = empty
        level.mines = [OceanMine(id: 1, position: CGPoint(x: 350, y: 300)),
                       OceanMine(id: 2, position: CGPoint(x: 900, y: 300))]
        level.rocks = [OceanRock(id: 1, vertices: [CGPoint(x: 380, y: 280), CGPoint(x: 420, y: 280), CGPoint(x: 400, y: 340)]),
                       OceanRock(id: 2, vertices: [CGPoint(x: 1000, y: 900), CGPoint(x: 1040, y: 900), CGPoint(x: 1020, y: 940)])]
        level.pickups = [OceanPickup(id: 7, kind: .battery, position: CGPoint(x: 500, y: 300)),
                         OceanPickup(id: 8, kind: .sample, position: CGPoint(x: 1200, y: 1300))]
        let engine = makeEngine(level: level)

        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "target" })
        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "base" })
        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "mine-1" })
        XCTAssertFalse(engine.sonarContacts.contains { $0.id == "mine-2" })
        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "reef-1" })
        XCTAssertFalse(engine.sonarContacts.contains { $0.id == "reef-2" })
        XCTAssertFalse(engine.sonarContacts.contains { $0.id == "pickup-7" })

        engine.activateSonar()
        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "pickup-7" })
        XCTAssertFalse(engine.sonarContacts.contains { $0.id == "pickup-8" })
        XCTAssertEqual(engine.sonarContacts.map(\.distanceMeters), engine.sonarContacts.map(\.distanceMeters).sorted())
    }

    func testNeutralBuoyancyDoesNotMoveOrDrainEnergy() {
        let engine = makeEngine()
        let position = engine.position
        advance(engine, 30)
        XCTAssertEqual(engine.position, position)
        XCTAssertEqual(engine.energy, 100)
        XCTAssertEqual(engine.state, .playing)
    }

    func testAllFourDirectionsAreControllable() {
        for vector in [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1)] {
            let engine = makeEngine()
            let initial = engine.position
            engine.setSteering(vector)
            advance(engine, 1)
            let displacement = (engine.position.x - initial.x) * vector.dx + (engine.position.y - initial.y) * vector.dy
            XCTAssertGreaterThan(displacement, 80)
            XCTAssertLessThan(engine.energy, 100)
        }
    }

    func testVoiceOverButtonsMoveThroughPhysicsAndStopAutomatically() {
        for vector in [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1)] {
            let engine = makeEngine()
            let initial = engine.position
            engine.moveForVoiceOver(vector)
            advance(engine, 0.2)
            let displacement = (engine.position.x - initial.x) * vector.dx + (engine.position.y - initial.y) * vector.dy
            XCTAssertGreaterThan(displacement, 2)
            XCTAssertLessThan(engine.energy, 100)
            advance(engine, 0.5)
            XCTAssertEqual(engine.steering, .zero)
            XCTAssertLessThan(engine.speed, 5)
        }
    }

    func testAccessibilityAnnouncementsOnlyAdvanceForEvents() {
        let engine = makeEngine()
        let initialRevision = engine.accessibilityAnnouncementRevision
        advance(engine, 1)
        XCTAssertEqual(engine.accessibilityAnnouncementRevision, initialRevision)
        engine.activateSonar()
        XCTAssertEqual(engine.accessibilityAnnouncementRevision, initialRevision + 1)
        advance(engine, 1)
        XCTAssertEqual(engine.accessibilityAnnouncementRevision, initialRevision + 1)
    }

    func testDiagonalInputDoesNotIncreaseTopSpeed() {
        let engine = makeEngine()
        engine.setSteering(CGVector(dx: 1, dy: 1))
        advance(engine, 1)
        XCTAssertEqual(engine.inputStrength, 1, accuracy: 0.0001)
        XCTAssertEqual(engine.speed, GameEngine.cruiseSpeed, accuracy: 0.1)
    }

    func testReleaseBrakesWithinShortPredictableDistance() {
        let engine = makeEngine()
        engine.setSteering(CGVector(dx: 1, dy: 0))
        advance(engine, 1)
        let releasedAt = engine.position
        engine.setSteering(.zero)
        advance(engine, 0.5)
        XCTAssertLessThan(engine.speed, 2)
        XCTAssertLessThan(engine.position.x - releasedAt.x, 12)
        let energy = engine.energy
        advance(engine, 5)
        XCTAssertEqual(engine.energy, energy)
    }

    func testOppositeInputReversesWithin150Milliseconds() {
        let engine = makeEngine()
        engine.setSteering(CGVector(dx: 1, dy: 0))
        advance(engine, 0.5)
        engine.setSteering(CGVector(dx: -1, dy: 0))
        advance(engine, 0.15)
        XCTAssertLessThan(engine.velocity.dx, 0)
        XCTAssertEqual(engine.facing, -1)
    }

    func testPhysicsAndEnergyMatchAt30_60And120FPS() {
        let engines = [30.0, 60.0, 120.0].map { fps -> GameEngine in
            let engine = makeEngine()
            for vector in [CGVector(dx: 1, dy: 0.5), CGVector(dx: -1, dy: 0), .zero] {
                engine.setSteering(vector)
                advance(engine, 1, fps: fps)
            }
            return engine
        }
        for engine in engines.dropFirst() {
            XCTAssertEqual(engine.position.x, engines[0].position.x, accuracy: 0.0001)
            XCTAssertEqual(engine.position.y, engines[0].position.y, accuracy: 0.0001)
            XCTAssertEqual(engine.energy, engines[0].energy, accuracy: 0.0001)
        }
    }

    func testBoostUsesEnergyAndRespectsCooldown() {
        let engine = makeEngine()
        engine.setSteering(CGVector(dx: 0, dy: 1))
        engine.activateBoost()
        XCTAssertEqual(engine.energy, 100 - GameEngine.boostCost)
        XCTAssertFalse(engine.canBoost)
        let energy = engine.energy
        engine.activateBoost()
        XCTAssertEqual(engine.energy, energy)
        advance(engine, 0.5)
        XCTAssertGreaterThan(engine.velocity.dy, 210)
        XCTAssertEqual(engine.velocity.dx, 0)
        advance(engine, 4.1)
        XCTAssertTrue(engine.canBoost)
        XCTAssertEqual(engine.boostRemaining, 0)
    }

    func testHeadlightBoostExpandsVisibilityAndRespectsEnergyDurationAndCooldown() {
        let engine = makeEngine()
        let normalRange = engine.headlightRange
        engine.activateLightBoost()
        XCTAssertEqual(engine.energy, 100 - GameEngine.lightBoostCost)
        XCTAssertTrue(engine.isLightBoostActive)
        XCTAssertGreaterThan(engine.headlightRange, normalRange * 2)
        XCTAssertFalse(engine.canLightBoost)
        let energy = engine.energy
        engine.activateLightBoost()
        XCTAssertEqual(engine.energy, energy, "An active light boost cannot be purchased twice")

        advance(engine, GameEngine.lightBoostDuration + 0.1)
        XCTAssertFalse(engine.isLightBoostActive)
        XCTAssertEqual(engine.headlightRange, normalRange)
        XCTAssertFalse(engine.canLightBoost)
        advance(engine, GameEngine.lightBoostRecharge - GameEngine.lightBoostDuration)
        XCTAssertTrue(engine.canLightBoost)
    }

    func testHeadlightBoostTimersFreezeWhilePaused() {
        let engine = makeEngine()
        engine.activateLightBoost()
        advance(engine, 0.5)
        engine.pause()
        let remaining = engine.lightBoostRemaining
        let cooldown = engine.lightBoostCooldown
        advance(engine, 30)
        XCTAssertEqual(engine.lightBoostRemaining, remaining)
        XCTAssertEqual(engine.lightBoostCooldown, cooldown)
    }

    func testAccessibleSurroundingsDescribeNearbyWorldEvents() {
        var level = empty
        level.mines = [OceanMine(id: 4, position: CGPoint(x: 390, y: 300))]
        level.pickups = [OceanPickup(id: 7, kind: .battery, position: CGPoint(x: 300, y: 410))]
        let engine = makeEngine(level: level)
        let description = engine.surroundingsDescription
        XCTAssertTrue(description.contains("Мина"))
        XCTAssertTrue(description.contains("батарея"))
        XCTAssertTrue(description.contains("цель"))
        XCTAssertTrue(engine.accessibilityStatus.contains("Энергия"))
    }

    func testSonarRevealsNearbyPickupsWithoutSpendingEnergy() {
        var level = empty
        level.pickups = [OceanPickup(id: 7, kind: .battery, position: CGPoint(x: 700, y: 400)),
                         OceanPickup(id: 8, kind: .sample, position: CGPoint(x: 1300, y: 1500))]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        XCTAssertFalse(engine.revealedPickups.contains(7))
        engine.activateSonar()
        XCTAssertTrue(engine.revealedPickups.contains(7))
        XCTAssertFalse(engine.revealedPickups.contains(8))
        XCTAssertEqual(engine.energy, 100)
        XCTAssertFalse(engine.canSonar)
        advance(engine, 8.1)
        XCTAssertTrue(engine.canSonar)
        XCTAssertTrue(engine.revealedPickups.contains(7), "A discovered item stays on the map")
    }

    func testPortalUsesChanceAndOnlyValidatedReachableCandidates() {
        var level = empty
        level.rocks = [OceanRock(id: 0, vertices: [CGPoint(x: 650, y: 650), CGPoint(x: 850, y: 650),
                                                       CGPoint(x: 850, y: 850), CGPoint(x: 650, y: 850)])]
        level.portalCandidates = [CGPoint(x: 750, y: 750), CGPoint(x: 520, y: 300)]
        XCTAssertNil(makeEngine(level: level, randomValues: [0.9]).portal)

        let engine = makeEngine(level: level, randomValues: [0.1, 0.8])
        XCTAssertEqual(engine.portal?.position, CGPoint(x: 520, y: 300))
        XCTAssertNil(level.rocks[0].contact(at: engine.portal!.position, radius: 54))
    }

    func testSonarAnnouncesPortalAndEnteringStartsBossLevel() {
        var level = empty
        level.portalCandidates = [level.spawn]
        let engine = makeEngine(level: level, randomValues: [0.1, 0])
        engine.activateSonar()
        XCTAssertTrue(engine.portalRevealed)
        XCTAssertTrue(engine.notice.contains("портал"))
        advance(engine, 0.01)
        XCTAssertEqual(engine.zone, .bossCave)
        XCTAssertNil(engine.portal)
        XCTAssertEqual(engine.bossTimeRemaining, GameEngine.bossDuration, accuracy: 0.6)
        XCTAssertTrue(engine.accessibilityStatus.contains("Пещера спрута"))
    }

    func testBossAttacksAreTelegraphedAndSurvivalReturnsRewardToOcean() {
        var level = empty
        level.portalCandidates = [level.spawn]
        let engine = makeEngine(level: level, randomValues: [0.1, 0])
        advance(engine, 0.01)
        let returnPoint = level.spawn
        var sawWarning = false
        for _ in 0..<300 where engine.zone == .bossCave && engine.state == .playing {
            if let strike = engine.bossStrike, strike.phase == .warning {
                sawWarning = true
                let goRight = strike.position.x < GameEngine.caveSize.width / 2
                    || engine.position.x < GameEngine.caveSize.width / 2
                engine.setSteering(CGVector(dx: goRight ? 1 : -1, dy: 0))
                engine.activateBoost()
            } else if engine.bossStrike?.phase == .impact {
                engine.setSteering(.zero)
            }
            advance(engine, 0.1)
        }
        XCTAssertTrue(sawWarning)
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.zone, .ocean)
        XCTAssertTrue(engine.bossDefeated)
        XCTAssertEqual(engine.bossReward, 300)
        XCTAssertEqual(engine.position.x, returnPoint.x, accuracy: 1)
        XCTAssertTrue(engine.notice.contains("Спрут отступил"))
    }

    func testPauseFreezesMinesResourcesAbilitiesAndAnimation() {
        var level = empty
        level.mines = [OceanMine(id: 0, position: CGPoint(x: 350, y: 300))]
        let engine = makeEngine(level: level)
        engine.activateSonar()
        engine.activateBoost()
        advance(engine, 0.1)
        engine.pause()
        let position = engine.position, energy = engine.energy, elapsed = engine.elapsed
        let fuse = engine.mines[0].timer, cooldown = engine.boostCooldown
        engine.setSteering(CGVector(dx: 1, dy: 1))
        engine.activateBoost()
        advance(engine, 10)
        XCTAssertEqual(engine.position, position)
        XCTAssertEqual(engine.energy, energy)
        XCTAssertEqual(engine.elapsed, elapsed)
        XCTAssertEqual(engine.mines[0].timer, fuse)
        XCTAssertEqual(engine.boostCooldown, cooldown)
        XCTAssertEqual(engine.steering, .zero)
        engine.togglePause()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.steering, .zero)
    }

    func testCurrentCarriesBoatAndCanBeSwumAgainst() {
        var level = empty
        level.currents = [OceanCurrent(id: 0, bounds: CGRect(x: 200, y: 200, width: 700, height: 600), velocity: CGVector(dx: 50, dy: 0))]
        let engine = makeEngine(level: level)
        advance(engine, 2)
        XCTAssertGreaterThan(engine.position.x, 380)
        XCTAssertEqual(engine.energy, 100)
        engine.setSteering(CGVector(dx: -1, dy: 0))
        advance(engine, 1)
        XCTAssertLessThan(engine.velocity.dx, -40)
    }

    func testMineTelegraphsBeforeExplodingAndOnlyDamagesOnce() {
        var level = empty
        level.mines = [OceanMine(id: 0, position: level.spawn)]
        let engine = makeEngine(level: level)
        advance(engine, 0.8)
        XCTAssertEqual(engine.mines[0].phase, .armed)
        XCTAssertEqual(engine.hull, 3)
        advance(engine, 0.6)
        XCTAssertEqual(engine.hull, 2)
        advance(engine, 4)
        XCTAssertEqual(engine.hull, 2)
        XCTAssertEqual(engine.mines[0].phase, .spent)
    }

    func testRetreatCanAvoidAnArmedMine() {
        var level = empty
        level.mines = [OceanMine(id: 0, position: CGPoint(x: 415, y: 300))]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        XCTAssertEqual(engine.mines[0].phase, .armed)
        engine.setSteering(CGVector(dx: -1, dy: 0))
        advance(engine, 1.9)
        XCTAssertEqual(engine.hull, 3)
        XCTAssertEqual(engine.mines[0].phase, .spent)
    }

    func testShieldAbsorbsOneHitAndOverlappingBlastsDoNotStack() {
        var level = empty
        level.pickups = [OceanPickup(id: 1, kind: .shield, position: level.spawn)]
        level.mines = [OceanMine(id: 0, position: level.spawn), OceanMine(id: 1, position: CGPoint(x: 305, y: 300))]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        XCTAssertTrue(engine.hasShield)
        advance(engine, 1.4)
        XCTAssertFalse(engine.hasShield)
        XCTAssertEqual(engine.hull, 3)
        XCTAssertEqual(engine.damageCount, 1)
    }

    func testBatteryIsNotWastedAtFullChargeAndCannotBeCollectedTwice() {
        var level = empty
        level.pickups = [OceanPickup(id: 1, kind: .battery, position: level.spawn)]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        XCTAssertFalse(engine.pickups[0].collected)
        engine.activateBoost()
        advance(engine, 0.1)
        XCTAssertTrue(engine.pickups[0].collected)
        XCTAssertGreaterThan(engine.energy, 99)
        XCTAssertLessThanOrEqual(engine.energy, 100)
        advance(engine, 3)
        navigate(engine, through: [level.spawn])
        XCTAssertEqual(engine.pickupCount, 1)
    }

    func testSlowRockContactStopsBoatAndFastImpactCostsOneHullPoint() {
        var level = empty
        level.rocks = [OceanRock(id: 0, vertices: [CGPoint(x: 440, y: 200), CGPoint(x: 540, y: 200), CGPoint(x: 540, y: 700), CGPoint(x: 440, y: 700)])]
        for strength: CGFloat in [0.4, 1] {
            let engine = makeEngine(level: level)
            engine.setSteering(CGVector(dx: strength, dy: 0))
            advance(engine, 5)
            XCTAssertLessThanOrEqual(engine.position.x, 420.1)
            XCTAssertEqual(engine.hull, strength == 1 ? 2 : 3)
        }
        let boosted = makeEngine(level: level)
        boosted.activateBoost()
        advance(boosted, 1)
        XCTAssertLessThanOrEqual(boosted.position.x, 420.1, "Boost must not tunnel through walls")
        XCTAssertEqual(boosted.hull, 2)
    }

    func testPolygonContactResolvesInsideAndDoesNotBlockEmptyCorners() {
        let rock = OceanRock(id: 0, vertices: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
        let p = CGPoint(x: 10, y: 50)
        let hit = rock.contact(at: p, radius: 20)
        XCTAssertNotNil(hit)
        if let hit {
            let outside = CGPoint(x: p.x + hit.normal.dx * (hit.penetration + 0.1), y: p.y + hit.normal.dy * (hit.penetration + 0.1))
            XCTAssertNil(rock.contact(at: outside, radius: 20))
        }
        XCTAssertNil(rock.contact(at: CGPoint(x: -19, y: -19), radius: 20))
    }

    func testBlackBoxMustBeReturnedAndDockingRequiresSlowingDown() {
        var level = empty
        level.pickups = [OceanPickup(id: 0, kind: .blackBox, position: level.spawn)]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        XCTAssertTrue(engine.hasBlackBox)
        XCTAssertEqual(engine.cargoValue, 600)
        XCTAssertEqual(engine.score, 0)
        XCTAssertEqual(engine.bestScore, 0)
        navigate(engine, through: [level.base])
        XCTAssertEqual(engine.state, .completed)
        XCTAssertEqual(engine.score, 600)
        XCTAssertEqual(engine.bestScore, 600)
    }

    func testBothCoastalRoutesCanReturnCargoWithEnergyOnDifferentScreens() {
        let routes: [[CGPoint]] = [
            [.init(x: 185, y: 1070), .init(x: 450, y: 1050), .init(x: 440, y: 1780),
             .init(x: 830, y: 1740), .init(x: 1490, y: 1740), .init(x: 1490, y: 2290), .init(x: 1370, y: 2330)],
            [.init(x: 800, y: 300), .init(x: 1510, y: 300), .init(x: 1510, y: 1250),
             .init(x: 1490, y: 1740), .init(x: 1490, y: 2290), .init(x: 1370, y: 2330)]
        ]
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844), CGSize(width: 430, height: 932)] {
            for route in routes {
                let engine = makeEngine(level: .expedition, size: size)
                navigate(engine, through: route)
                XCTAssertTrue(engine.hasBlackBox)
                XCTAssertEqual(engine.state, .playing)
                navigate(engine, through: Array(route.dropLast().reversed()) + [engine.level.base])
                XCTAssertEqual(engine.state, .completed, "Route failed: energy \(engine.energy), hull \(engine.hull), position \(engine.position)")
                XCTAssertGreaterThan(engine.energy, 0)
                XCTAssertEqual(engine.hull, 3)
                XCTAssertGreaterThanOrEqual(engine.score, 600)
            }
        }
    }

    func testShortRouteThroughMinesIsSurvivableWithShield() {
        let engine = makeEngine(level: .expedition)
        let route: [CGPoint] = [.init(x: 790, y: 350), .init(x: 790, y: 470), .init(x: 730, y: 1000),
                                .init(x: 1140, y: 1070), .init(x: 1190, y: 1470),
                                .init(x: 1490, y: 1740), .init(x: 1490, y: 2290), .init(x: 1370, y: 2330)]
        navigate(engine, through: route)
        XCTAssertTrue(engine.hasBlackBox)
        XCTAssertLessThan(engine.hull, 3)
        navigate(engine, through: Array(route.dropLast().reversed()) + [engine.level.base])
        XCTAssertEqual(engine.state, .completed)
        XCTAssertGreaterThanOrEqual(engine.score, 600)
    }

    func testEnergyFailureLosesUndeliveredCargoAndDoesNotRestartOnInput() {
        var level = empty
        level.pickups = [OceanPickup(id: 0, kind: .blackBox, position: level.spawn)]
        let engine = makeEngine(level: level)
        advance(engine, 0.1)
        engine.setSteering(CGVector(dx: -1, dy: 0))
        advance(engine, 95)
        XCTAssertEqual(engine.state, .gameOver)
        XCTAssertEqual(engine.failureReason, .energy)
        XCTAssertEqual(engine.score, 0)
        XCTAssertEqual(engine.bestScore, 0)
        engine.setSteering(CGVector(dx: 1, dy: 0))
        engine.activateBoost()
        advance(engine, 1)
        XCTAssertEqual(engine.state, .gameOver)
        engine.startGame()
        XCTAssertEqual(engine.energy, 100)
        XCTAssertEqual(engine.hull, 3)
        XCTAssertFalse(engine.hasBlackBox)
        XCTAssertFalse(engine.pickups[0].collected)
    }

    func testThreeSeparateHitsEndExpeditionAndFreezeDamage() {
        var level = empty
        level.mines = [300.0, 650.0, 1000.0].enumerated().map { index, x in
            OceanMine(id: index, position: CGPoint(x: x, y: 300))
        }
        let engine = makeEngine(level: level)
        advance(engine, 1.5)
        XCTAssertEqual(engine.hull, 2)
        navigate(engine, through: [.init(x: 650, y: 300), .init(x: 1000, y: 300)])
        advance(engine, 2)
        XCTAssertEqual(engine.state, .gameOver)
        XCTAssertEqual(engine.failureReason, .hull)
        XCTAssertEqual(engine.hull, 0)
        attachResultScreen(engine, name: "Expedition-failure-iPhone", size: CGSize(width: 390, height: 844))
        let damage = engine.damageCount
        advance(engine, 10)
        XCTAssertEqual(engine.damageCount, damage)
    }

    func testNewRecordPersistsSeparatelyFromLegacyReefScore() {
        let suite = "ExpeditionTests.record.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(99, forKey: "podlodkaDive.bestScore")
        var level = empty
        level.pickups = [OceanPickup(id: 0, kind: .blackBox, position: level.spawn), OceanPickup(id: 1, kind: .sample, position: level.spawn)]
        let engine = makeEngine(level: level, defaults: defaults)
        XCTAssertEqual(engine.bestScore, 0)
        advance(engine, 0.1)
        navigate(engine, through: [level.base])
        XCTAssertEqual(engine.score, 675)
        XCTAssertTrue(engine.isNewRecord)
        attachResultScreen(engine, name: "Expedition-delivered-iPhone-SE", size: CGSize(width: 375, height: 667))
        let restored = makeEngine(defaults: defaults)
        XCTAssertEqual(restored.bestScore, 675)
        XCTAssertEqual(defaults.integer(forKey: "podlodkaDive.bestScore"), 99)
    }

    func testResizePausesButDoesNotMoveWorldObjects() {
        let engine = makeEngine(level: .expedition)
        engine.setSteering(CGVector(dx: 1, dy: 0))
        advance(engine, 0.2)
        let position = engine.position
        engine.resize(to: CGSize(width: 375, height: 667))
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.position, position)
        XCTAssertEqual(engine.steering, .zero)
        let screen = engine.screenPoint(position)
        XCTAssertTrue(CGRect(origin: .zero, size: engine.viewport).contains(screen))
    }

    func testInvalidInputAndLongStallsCannotCorruptTheWorld() {
        let engine = makeEngine()
        let position = engine.position
        engine.setSteering(CGVector(dx: CGFloat.nan, dy: CGFloat.infinity))
        for time in [Double.nan, .infinity, -1, 0] { engine.step(deltaTime: time) }
        XCTAssertEqual(engine.position, position)
        engine.setSteering(CGVector(dx: 1, dy: 0))
        engine.step(deltaTime: 60)
        XCTAssertLessThan(engine.position.x - position.x, 5)
        XCTAssertEqual(engine.runElapsed, 0.1, accuracy: 0.0001)
    }

    func testLevelObjectsAreReachableOutsideRockGeometry() {
        let level = OceanLevel.expedition
        let points = level.pickups.map(\.position) + level.mines.map(\.position) + [level.spawn, level.base]
        for p in points {
            for rock in level.rocks { XCTAssertNil(rock.contact(at: p, radius: GameEngine.hullRadius), "Object inside rock at \(p)") }
        }
    }
    func testAccessibilityPickupAndMineEventOrder() {
        var level = empty
        level.pickups = [.init(id: 0, kind: .battery, position: level.spawn),
                         .init(id: 1, kind: .shield, position: level.spawn),
                         .init(id: 2, kind: .sample, position: level.spawn),
                         .init(id: 3, kind: .blackBox, position: level.spawn)]
        level.mines = [.init(id: 0, position: level.spawn)]
        let engine = makeEngine(level: level)
        var events: [GameEvent] = []
        let token = engine.events.sink { if case .situation = $0 {} else { events.append($0) } }
        defer { token.cancel() }
        engine.activateBoost()
        advance(engine, 0.01)
        XCTAssertEqual(events, [.speak("Мина активирована — отойди!"),
                                .speak("Батарея · +30 энергии"), .speak("Щит · защита от одного удара"),
                                .speak("Образец на борту · +75 к добыче"), .objectiveChanged(true),
                                .speak("Чёрный ящик найден. Вернись на базу!")])
        // Separate stationary fixture guarantees the mine hits rather than boosting away.
        let stationary = makeEngine(level: level)
        var hits: [GameEvent] = []
        let hitToken = stationary.events.sink { if case .situation = $0 {} else { hits.append($0) } }
        defer { hitToken.cancel() }
        advance(stationary, 3)
        XCTAssertEqual(hits.filter { $0 == .speak("Мина активирована — отойди!") }.count, 1)
        XCTAssertEqual(hits.filter { $0 == .speak("Щит поглотил удар") }.count, 1)
        XCTAssertLessThan(hits.firstIndex(of: .speak("Мина активирована — отойди!"))!, hits.firstIndex(of: .speak("Щит поглотил удар"))!)
        level.pickups = []
        let unshielded = makeEngine(level: level)
        var damage: [GameEvent] = []
        let damageToken = unshielded.events.sink { damage.append($0) }
        defer { damageToken.cancel() }
        advance(unshielded, 3)
        XCTAssertEqual(damage.filter { $0 == .speak("Корпус повреждён · 2/3") }.count, 1)
    }

    func testAccessibilityEnergyWarningAndEndExactlyOncePerRun() {
        let engine = makeEngine()
        var events: [GameEvent] = []
        let token = engine.events.sink { if case .situation = $0 {} else { events.append($0) } }
        defer { token.cancel() }
        for _ in 0..<2 {
            engine.setSteering(CompassCourse.e.vector)
            advance(engine, 95)
            XCTAssertEqual(Array(events.suffix(3)), [.energyLow, .speak("Энергия закончилась"), .stateChanged(.gameOver)])
            engine.startGame()
        }
        XCTAssertEqual(events.filter { $0 == .energyLow }.count, 2)
        XCTAssertEqual(events.filter { $0 == .speak("Энергия закончилась") }.count, 2)
    }

    func testSituationDeterminismFrequencyAndCompassGeometry() {
        var runs: [[SituationSummary]] = []
        for fps in [30.0, 60, 120] {
            let engine = makeEngine()
            var summaries: [SituationSummary] = []
            var times: [Double] = []
            let token = engine.events.sink {
                if case .situation(let summary) = $0 { summaries.append(summary); times.append(engine.runElapsed) }
            }
            engine.setSteering(CompassCourse.ne.vector)
            advance(engine, 3, fps: fps)
            XCTAssertEqual(summaries.count, 12)
            for pair in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, 0.25 - 0.0001) }
            let vector = CGVector(dx: engine.target.x - engine.position.x, dy: engine.target.y - engine.position.y)
            XCTAssertEqual(summaries.last?.targetCourse, CompassCourse(vector: vector))
            engine.pause(); advance(engine, 1, fps: fps)
            XCTAssertEqual(summaries.count, 12)
            token.cancel(); runs.append(summaries)
        }
        XCTAssertEqual(runs[0], runs[1]); XCTAssertEqual(runs[1], runs[2])
        for course in CompassCourse.allCases {
            XCTAssertEqual(CompassCourse(vector: course.vector), course)
            XCTAssertEqual(hypot(course.vector.dx, course.vector.dy), 1, accuracy: 0.0001)
        }
    }

    func testCompassAndStickUseIdenticalPhysics() {
        let diagonal = 1 / sqrt(CGFloat(2))
        for (course, stick) in [(CompassCourse.n, CGVector(dx: 0, dy: -1)),
                                (.ne, CGVector(dx: diagonal, dy: -diagonal)), (.e, CGVector(dx: 1, dy: 0))] {
            let a = makeEngine(), b = makeEngine()
            a.setSteering(steeringVector(for: course)); b.setSteering(stick)
            advance(a, 1); advance(b, 1)
            XCTAssertEqual(a.position.x, b.position.x, accuracy: 0.0001)
            XCTAssertEqual(a.position.y, b.position.y, accuracy: 0.0001)
            XCTAssertEqual(a.energy, b.energy, accuracy: 0.0001)
        }
    }

    func testDeliveryAndRecordEventsPrecedeCompletedOnce() {
        var level = OceanLevel(size: empty.size, spawn: empty.spawn, base: empty.spawn, wreck: empty.wreck)
        level.pickups = [.init(id: 0, kind: .blackBox, position: level.spawn)]
        let engine = makeEngine(level: level)
        var events: [GameEvent] = []
        let token = engine.events.sink { events.append($0) }
        defer { token.cancel() }
        advance(engine, 1)
        XCTAssertEqual(events, [.objectiveChanged(true), .speak("Чёрный ящик найден. Вернись на базу!"),
                                .success(600), .record(600), .stateChanged(.completed)])
    }

}
