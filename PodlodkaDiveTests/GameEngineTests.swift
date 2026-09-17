import UserNotifications

import XCTest
import SwiftData
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
        let engine = GameEngine(defaults: storage, level: level ?? empty, journal: DiscardJournal(),
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

    func testJournalLeakIsThrottledExpiresAndFreezesOnPause() {
        let engine = makeEngine()
        XCTAssertEqual(engine.journalLeak?.phrase, "Капитан: погружаемся!")
        engine.activateBoost()
        engine.activateSonar()
        XCTAssertEqual(engine.journalLeak?.phrase, "Капитан: погружаемся!")
        XCTAssertTrue(engine.crewJournal.entries.contains { $0.message == "Форсаж включён" })
        engine.pause()
        let time = engine.runElapsed
        advance(engine, 10)
        XCTAssertEqual(engine.runElapsed, time)
        XCTAssertNotNil(engine.journalLeak)
        engine.togglePause()
        advance(engine, 4.6)
        XCTAssertNil(engine.journalLeak)
        XCTAssertTrue(engine.canBoost)
        engine.activateBoost()
        XCTAssertNil(engine.journalLeak, "A new bubble must wait eight seconds, even after the old one expired")
        advance(engine, 11.4)
        XCTAssertTrue(engine.journalLeak?.phrase.hasPrefix("Штурман:") == true)
        XCTAssertTrue(engine.crewJournal.entries.contains { $0.level == .state && $0.message == "Плановый доклад экипажа" })
    }

    func testJournalRetainsRunsAndRecordsFailureSnapshot() {
        let engine = makeEngine()
        engine.prepareAccessibilityAuditState("gameOver")
        let failure = engine.crewJournal.entries.last!
        XCTAssertEqual(failure.level, .error)
        XCTAssertEqual(failure.message, "Энергия закончилась")
        XCTAssertTrue(failure.snapshot.contains("gameOver"))
        engine.startGame()
        XCTAssertEqual(engine.expeditionNumber, 3)
        XCTAssertTrue(engine.crewJournal.entries.contains { $0.id == failure.id })
        XCTAssertEqual(engine.journalLeak?.startedAt, 0)
    }

    func testJournalEvictsOldestRecordsAtCapacity() {
        let logger = CrewEventLog()
        for index in 0..<510 {
            logger.record(expedition: 1, seconds: Double(index), level: .event,
                          message: "Event \(index)", snapshot: "State")
        }
        XCTAssertEqual(logger.entries.count, 500)
        XCTAssertEqual(logger.entries.first?.message, "Event 10")
        XCTAssertEqual(logger.entries.last?.message, "Event 509")
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

    func testCrystalWalletAndPurchasesSurviveReload() {
        let suite = "GarageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var level = empty
        level.pickups = [OceanPickup(id: 1, kind: .crystal, position: level.spawn),
                         OceanPickup(id: 2, kind: .crystal, position: level.spawn)]
        let engine = makeEngine(level: level, defaults: defaults)
        advance(engine, 0.1)
        XCTAssertEqual(engine.crystals, 20)
        advance(engine, 1)
        XCTAssertEqual(engine.crystals, 20, "A pickup must credit only once per expedition")
        engine.customize(.neon)
        XCTAssertFalse(engine.owns(.neon), "Purchasing during a run is forbidden")
        engine.returnToMenu()
        engine.customize(.chrome)
        XCTAssertEqual(engine.crystals, 20)
        XCTAssertFalse(engine.owns(.chrome))
        engine.customize(.neon)
        XCTAssertEqual(engine.crystals, 0)
        XCTAssertEqual(engine.selectedStyle, .neon)
        engine.customize(.classic)
        engine.customize(.neon)
        XCTAssertEqual(engine.crystals, 0, "Owned styles equip for free")
        let restored = GameEngine(defaults: defaults, level: level, journal: DiscardJournal())
        XCTAssertEqual(restored.selectedStyle, .neon)
        XCTAssertTrue(restored.owns(.neon))
        XCTAssertEqual(restored.crystals, 0)
        restored.startGame()
        advance(restored, 0.1)
        XCTAssertEqual(restored.crystals, 20, "New expeditions replenish crystal pickups")
        XCTAssertEqual(restored.selectedStyle, .neon)
    }

    func testCrystalsPersistWithoutFinishingExpedition() {
        let suite = "GarageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var level = empty
        level.pickups = [OceanPickup(id: 1, kind: .crystal, position: level.spawn)]
        let engine = makeEngine(level: level, defaults: defaults)
        advance(engine, 0.1)
        XCTAssertEqual(GameEngine(defaults: defaults, journal: DiscardJournal()).crystals, 10)
        XCTAssertEqual(engine.cargoValue, 0, "Crystals do not change salvage scoring")
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
        advance(engine, 0.1)
        let description = engine.surroundingsDescription
        XCTAssertTrue(description.contains(A11yL10n.contactKind(.mine)))
        XCTAssertTrue(engine.sonarContacts.contains { $0.kind == .battery })
        XCTAssertTrue(description.contains(A11yL10n.text("a11y.objective.blackbox", defaultValue: "Найти чёрный ящик")))
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

        let engine = makeEngine(level: level, randomValues: [0.1, 0.0])
        XCTAssertEqual(engine.portal?.position, CGPoint(x: 520, y: 300))
        XCTAssertNil(level.rocks[0].contact(at: engine.portal!.position, radius: 54))
    }

    func testSonarAnnouncesPortalAndEnteringStartsBossLevel() {
        var level = empty
        level.portalCandidates = [level.spawn]
        let engine = makeEngine(level: level, randomValues: [0.1, 0])
        engine.activateSonar()
        XCTAssertTrue(engine.portalRevealed)
        XCTAssertEqual(engine.notice, A11yL10n.text("event.portal.revealed", defaultValue: "Сонар обнаружил портал в пещеру"))
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
        XCTAssertEqual(engine.notice, A11yL10n.text("event.boss.complete", defaultValue: "Спрут отступил! Артефакт пещеры добавил 300 к добыче."))
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
        XCTAssertEqual(events, [.danger(A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!")),
                                .speak(A11yL10n.text("event.battery", defaultValue: "Батарея. Плюс 30 энергии")), .speak(A11yL10n.text("event.shield", defaultValue: "Щит. Защита от одного удара")),
                                .speak(A11yL10n.text("event.sample", defaultValue: "Образец на борту. Плюс 75 к добыче")), .objectiveChanged(true),
                                .speak(A11yL10n.text("event.blackbox", defaultValue: "Чёрный ящик найден. Вернись на базу!")),
                                .speak(A11yL10n.text("event.docking", defaultValue: "База рядом. Остановись в круге базы для швартовки."))])
        // Separate stationary fixture guarantees the mine hits rather than boosting away.
        let stationary = makeEngine(level: level)
        var hits: [GameEvent] = []
        let hitToken = stationary.events.sink { if case .situation = $0 {} else { hits.append($0) } }
        defer { hitToken.cancel() }
        advance(stationary, 3)
        XCTAssertEqual(hits.filter { $0 == .danger(A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!")) }.count, 1)
        XCTAssertEqual(hits.filter { $0 == .danger(A11yL10n.text("event.shield.hit", defaultValue: "Щит поглотил удар")) }.count, 1)
        XCTAssertEqual(hits.filter { if case .danger = $0 { return true }; return false }.prefix(2), [.danger(A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!")), .danger(A11yL10n.text("event.shield.hit", defaultValue: "Щит поглотил удар"))])
        level.pickups = []
        let unshielded = makeEngine(level: level)
        var damage: [GameEvent] = []
        let damageToken = unshielded.events.sink { damage.append($0) }
        defer { damageToken.cancel() }
        advance(unshielded, 3)
        XCTAssertEqual(damage.filter { $0 == .danger(A11yL10n.format("event.hull.damage.format", defaultValue: "Корпус повреждён. %lld из 3", Int64(2))) }.count, 1)
    }

    func testAccessibilityEnergyWarningAndEndExactlyOncePerRun() {
        let engine = makeEngine()
        var events: [GameEvent] = []
        let token = engine.events.sink { if case .situation = $0 {} else { events.append($0) } }
        defer { token.cancel() }
        for _ in 0..<2 {
            engine.setSteering(CompassCourse.e.vector)
            advance(engine, 95)
            XCTAssertEqual(Array(events.suffix(4)), [.energyLow, .danger(A11yL10n.text("event.energy.empty", defaultValue: "Энергия закончилась")), .stateChanged(.gameOver), .runEnded("gameOver")])
            engine.startGame()
        }
        XCTAssertEqual(events.filter { $0 == .energyLow }.count, 2)
        XCTAssertEqual(events.filter { $0 == .danger(A11yL10n.text("event.energy.empty", defaultValue: "Энергия закончилась")) }.count, 2)
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
        XCTAssertEqual(events, [.objectiveChanged(true), .speak(A11yL10n.text("event.blackbox", defaultValue: "Чёрный ящик найден. Вернись на базу!")),
                                .success(600), .record(600), .stateChanged(.completed), .runEnded("completed")])
    }

    func testHiddenCrystalStaysHiddenInAllNavigationUntilRevealed() {
        // given: light reaches this crystal, passive discovery does not.
        var level = empty
        level.pickups = [.init(id: 80, kind: .crystal, position: CGPoint(x: 800, y: 300))]
        let engine = makeEngine(level: level)
        engine.activateLightBoost()
        advance(engine, 0.1)

        // when / then: light cannot bypass sonar discovery.
        XCTAssertFalse(engine.sonarContacts.contains { $0.id == "pickup-80" })
        XCTAssertNil(engine.situationSummary.find)
        XCTAssertFalse(engine.surroundingsDescription.contains(A11yL10n.contactKind(.crystal)))
        engine.activateSonar()
        XCTAssertTrue(engine.sonarContacts.contains { $0.id == "pickup-80" && $0.kind == .crystal })
        XCTAssertEqual(engine.situationSummary.find?.id, "pickup:80")
        XCTAssertTrue(engine.surroundingsDescription.contains(A11yL10n.contactKind(.crystal)))
    }

    func testCaveNavigationAndAnnouncementsExcludeOceanContacts() {
        // given: an ocean contact and current would otherwise leak into cave coordinates.
        var level = empty
        level.portalCandidates = [level.spawn]
        level.pickups = [.init(id: 80, kind: .crystal, position: CGPoint(x: 400, y: 300))]
        level.currents = [.init(id: 8, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), velocity: CGVector(dx: 30, dy: 0))]
        let engine = makeEngine(level: level, randomValues: [0, 0])
        var events: [GameEvent] = []
        let token = engine.events.sink { events.append($0) }
        defer { token.cancel() }

        engine.activateSonar()
        XCTAssertNotNil(engine.situationSummary.find)

        // when
        advance(engine, 1.8)

        // then
        XCTAssertEqual(engine.zone, .bossCave)
        XCTAssertEqual(Set(engine.sonarContacts.map(\.id)), ["boss", "tentacle"])
        XCTAssertNil(engine.situationSummary.find)
        XCTAssertNil(engine.situationSummary.currentCourse)
        XCTAssertEqual(engine.situationSummary.danger?.id, "tentacle")
        XCTAssertNotNil(engine.situationSummary.caveTimeRemaining)
        XCTAssertTrue(VoiceOverAnnouncer.format(engine.situationSummary).hasPrefix(A11yL10n.format("speech.cave", defaultValue: "Пещера спрута. Продержись ещё %lld секунд.", Int64(engine.situationSummary.caveTimeRemaining ?? -1))))
        XCTAssertTrue(events.contains { if case .danger(let text) = $0 { return text == A11yL10n.text("event.tentacle.warning", defaultValue: "Удар щупальца! Уходи в сторону или используй форсаж.") }; return false })
    }

    func testLightBoostWarnsAtThresholdAndEndsRunAtZeroEnergy() {
        // given
        let engine = makeEngine()
        var events: [GameEvent] = []
        let token = engine.events.sink { events.append($0) }
        defer { token.cancel() }

        // when
        for index in 0..<19 {
            engine.activateLightBoost()
            if index == 14 { XCTAssertEqual(events.filter { $0 == .energyLow }.count, 1) }
            advance(engine, GameEngine.lightBoostRecharge + 0.1)
        }
        XCTAssertEqual(engine.energy, 5)
        engine.activateLightBoost()

        // then: no extra physics tick is needed to finish.
        XCTAssertEqual(engine.state, .gameOver)
        XCTAssertEqual(engine.failureReason, .energy)
        XCTAssertFalse(engine.isLightBoostActive)
        XCTAssertEqual(events.filter { $0 == .energyLow }.count, 1)
    }

    func testEveryUrgentEventReachesTheSingleSpeechSinkAndVoiceOverOffDropsIt() {
        // given: repeated mine text represents two different mines, not a repeated frame.
        let engine = makeEngine()
        var enabled = true
        var spoken: [NSAttributedString] = []
        let announcer = VoiceOverAnnouncer(engine: engine, voiceOverRunning: { enabled }, post: { spoken.append($0) })
        let warning = A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!")

        // when
        engine.events.send(.danger(warning))
        engine.events.send(.danger(warning))
        enabled = false
        engine.events.send(.danger("must not be spoken"))
        enabled = true
        engine.events.send(.danger(warning))

        // then
        XCTAssertEqual(spoken.map(\.string), [warning, warning, warning])
        XCTAssertTrue(spoken.allSatisfy { ($0.attribute(.accessibilitySpeechQueueAnnouncement, at: 0, effectiveRange: nil) as? Bool) == false })
        withExtendedLifetime(announcer) {}
    }

    func testApproachWarningsEscalateAndRearmWithoutRepeatingEachFrame() {
        // given
        let engine = makeEngine()
        var spoken: [String] = []
        let announcer = VoiceOverAnnouncer(engine: engine, voiceOverRunning: { true }, now: { 10 }, post: { spoken.append($0.string) })
        func summary(distance: Int) -> SituationSummary {
            .init(depth: 10, speed: 5, returning: false, targetDistance: 100, targetCourse: .e,
                  danger: .init(id: "reef", name: "Reef", distance: distance, course: .e),
                  find: nil, currentCourse: nil, currentSpeed: 0, caveTimeRemaining: nil)
        }

        // when
        for distance in [25, 25, 25, 15, 15, 7, 7, 40, 25] {
            engine.events.send(.situation(summary(distance: distance)))
        }

        // then: near, danger, critical, then a new approach.
        XCTAssertEqual(spoken, [25, 15, 7, 25].map {
            A11yL10n.format("speech.danger", defaultValue: "Опасность. %@, %lld метров, %@.", "Reef", Int64($0), CompassCourse.e.label)
        })
        withExtendedLifetime(announcer) {}
    }

    func testSelectingVoiceOverCourseSurvivesRegularViewUpdates() {
        // given
        let steering = SteeringSurface()
        steering.updateAccessibility(steering: .zero, contacts: [])

        // when: choose east while stationary, then receive another display refresh.
        steering.accessibilityIncrement()
        steering.accessibilityIncrement()
        steering.updateAccessibility(steering: .zero, contacts: [])

        // then: the value must retain the selected direction rather than read only Stop.
        let expected = A11yL10n.format("a11y.steering.value.format", defaultValue: "Курс: %@, тяга %lld процентов",
                                      A11yL10n.text("a11y.course.stop", defaultValue: "стоп"), Int64(0))
            + ". " + A11yL10n.format("a11y.selected.course", defaultValue: "Выбран курс: %@", CompassCourse.e.label)
        XCTAssertEqual(steering.accessibilityValue, expected)
    }


}

// MARK: - Expedition black box
@MainActor final class BlackBoxTests: XCTestCase {
    private func store() throws -> BlackBoxStore {
        BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    func testVolumeBatchPaginationAndConcurrentOrder() async throws {
        let store = try store(), id = UUID()
        let logger = BlackBox(store: store, sleep: { throw CancellationError() })
        await logger.recover()
        await logger.log(.info, .state, "run.start", runID: id, t: 0)
        for i in 1..<63 { await logger.log(.info, .event, "event", runID: id, t: Double(i)) }
        let reader = BlackBoxReader(store: store)
        let before = try await reader.page(runID: id)
        XCTAssertTrue(before.isEmpty)
        await logger.log(.error, .hazard, "damage", runID: id, t: 63)
        let batch = try await reader.page(runID: id)
        XCTAssertEqual(batch.count, 64)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<600 { group.addTask { await logger.log(.info, .event, "concurrent", runID: id, t: Double(i)) } }
        }
        await logger.flush()
        let all = try await reader.all(runID: id)
        XCTAssertEqual(all.count, 664)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(all.map(\.seq), Array(1...664))
        let json = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode([BlackBoxEntry].self, from: json), all)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(id.uuidString))
    }
    func testRecoveryIsIdempotentAndRetentionKeepsTenRuns() async throws {
        let store = try store()
        let ids = (0..<12).map { _ in UUID() }
        for i in 0..<12 {
            try await store.write([BlackBoxEntry(runID: ids[i], seq: i + 1, t: 0, wallTime: Date(timeIntervalSince1970: Double(i)), level: .info, category: .state, message: "run.start", attrs: [:])])
        }
        _ = try await store.recoverAndPrune()
        _ = try await store.recoverAndPrune()
        let reader = BlackBoxReader(store: store)
        let runs = try await reader.runs()
        XCTAssertEqual(runs, Array(ids.suffix(10).reversed()))
        let entries = try await reader.all()
        XCTAssertEqual(entries.filter { $0.attrs["outcome"] == "interrupted" }.count, 10)
    }
    func testRecorderCapturesSnapshotsDenialsAndFinalState() async throws {
        let store = try store(), logger = BlackBox(store: store)
        let engine = GameEngine(randomValue: { 1 })
        let recorder = BlackBoxRecorder(engine: engine, logger: logger)
        engine.startGame()
        engine.activateBoost(); engine.activateBoost()
        for _ in 0..<120 { engine.step(deltaTime: 1.0 / 120) }
        engine.returnToMenu()
        await recorder.drain()
        let entries = try await BlackBoxReader(store: store).all()
        XCTAssertEqual(entries.filter { $0.message == "run.start" }.count, 1)
        XCTAssertEqual(entries.filter { $0.message == "run.end" }.count, 1)
        XCTAssertEqual(entries.filter { $0.message == "snapshot" }.count, 1)
        XCTAssertTrue(entries.contains { $0.message == "ability.denied" && $0.attrs["reason"] == "cooldown" })
        let samples = entries.compactMap(ReplaySample.init)
        XCTAssertEqual(samples.last?.x, Double(engine.position.x))
        XCTAssertEqual(samples.last?.energy, Double(engine.energy))
    }
    func testInterpolationClampsAndDoesNotInterpolateDiscreteHull() {
        let samples = [ReplaySample(t: 0, x: 0, y: 10, energy: 100, hull: 3, speed: 0), ReplaySample(t: 10, x: 100, y: 30, energy: 80, hull: 2, speed: 20)]
        let middle = ReplaySample.interpolate(samples, at: 5)
        XCTAssertEqual(middle?.x, 50); XCTAssertEqual(middle?.energy, 90)
        XCTAssertEqual(middle?.hull, 3); XCTAssertEqual(middle?.speed, 10)
        XCTAssertEqual(ReplaySample.interpolate(samples, at: -1)?.x, 0)
        XCTAssertEqual(ReplaySample.interpolate(samples, at: 20)?.x, 100)
    }
    func testInjectedCaptainText() async throws {
        final class Transcriber: VoiceNoteTranscriber {
            func start(update: @escaping @MainActor (String) -> Void, failure: @escaping @MainActor (String) -> Void) async throws { update("Aster найден") }
            func stop() {}
        }
        let store = try store(), logger = BlackBox(store: store)
        let engine = GameEngine(randomValue: { 1 })
        let recorder = BlackBoxRecorder(engine: engine, logger: logger)
        engine.startGame()
        let note = CaptainNote(transcriber: Transcriber())
        await note.toggle(recorder: recorder)
        XCTAssertTrue(note.recording)
        note.finish(recorder: recorder)
        await recorder.drain()
        let entries = try await BlackBoxReader(store: store).all()
        XCTAssertEqual(entries.filter { $0.category == .captain }.map(\.message), ["Aster найден"])
        XCTAssertEqual(engine.state, .playing)
    }
}

extension BlackBoxTests {
    func testDatabaseReopensWithoutDuplicates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let configuration = ModelConfiguration(url: url)
        let id = UUID()
        let entry = BlackBoxEntry(runID: id, seq: 1, t: 0, wallTime: Date(), level: .info, category: .state, message: "run.start", attrs: [:])
        let first = BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self, configurations: configuration))
        try await first.write([entry]); try await first.write([entry])
        let second = BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self, configurations: configuration))
        let entries = try await BlackBoxReader(store: second).all(runID: id)
        XCTAssertEqual(entries, [entry])
    }
    func testTimerFlushUsesInjectedSchedulerAndWallClock() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            func sleep() async { await withCheckedContinuation { continuation = $0 } }
            func ready() -> Bool { continuation != nil }
            func tick() { continuation?.resume(); continuation = nil }
        }
        let gate = Gate(), store = try store(), id = UUID()
        let date = Date(timeIntervalSince1970: 123)
        let logger = BlackBox(store: store, now: { date }, sleep: { await gate.sleep() })
        await logger.log(.info, .state, "run.start", runID: id, t: 0)
        let timerStarted = expectation(description: "Timer schedules a flush")
        let observer = Task {
            while !Task.isCancelled {
                if await gate.ready() { timerStarted.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [timerStarted], timeout: 2)
        observer.cancel()
        await gate.tick()
        var entries: [BlackBoxEntry] = []
        for _ in 0..<200 {
            entries = try await BlackBoxReader(store: store).all()
            if !entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.wallTime, date)
    }
}

extension GameEngineTests {
    func testScriptedRunBlackBoxEventOrderAndTrajectory() async throws {
        var level = empty
        level.pickups = [.init(id: 0, kind: .shield, position: level.spawn),
                         .init(id: 1, kind: .blackBox, position: CGPoint(x: 650, y: 300))]
        level.mines = [.init(id: 0, position: CGPoint(x: 500, y: 300))]
        let engine = GameEngine(level: level, randomValue: { 1 })
        let store = BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let logger = BlackBox(store: store)
        let recorder = BlackBoxRecorder(engine: engine, logger: logger)
        var expected: [String] = []
        var trajectory: [CGPoint] = []
        var ticks = 0
        let token = engine.events.sink { event in
            switch event {
            case .speak(let text), .danger(let text): expected.append(text)
            case .situation(let summary):
                ticks += 1; if ticks % 4 == 0 { trajectory.append(summary.position) }
            default: break
            }
        }
        defer { token.cancel() }
        engine.resize(to: CGSize(width: 390, height: 844)); engine.startGame()
        navigate(engine, through: [CGPoint(x: 650, y: 300)])
        navigate(engine, through: [level.base])
        await recorder.drain()
        let entries = try await BlackBoxReader(store: store).all()
        let actual = entries.filter { ($0.category == .event && $0.message != "blackBox" && $0.message != "success" && $0.message != "record") || $0.category == .hazard }.map(\.message)
        XCTAssertEqual(actual, expected)
        let captured = entries.filter { $0.message == "snapshot" }.compactMap(ReplaySample.init)
        XCTAssertEqual(captured.map { CGPoint(x: $0.x, y: $0.y) }, trajectory)
        XCTAssertTrue(entries.contains { $0.message == "blackBox" })
    }
}

@MainActor
final class ExpeditionJournalTests: XCTestCase {
    private func location() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.sqlite")
    }

    private func entry(_ dive: UUID, _ index: Int, kind: String = "snapshot") -> JournalEntry {
        JournalEntry(id: UUID(), diveID: dive, date: Date(timeIntervalSince1970: Double(index)),
            elapsed: Double(index), kind: kind, severity: "info", message: "Событие '\(index)'",
            boat: BoatSnapshot(x: 1, y: 2, energy: 93, hull: 2, cargo: 600,
                blackBox: true, shield: false, zone: "ocean", state: "playing", speed: 10))
    }

    func testBatchesSurviveReopenWithPaginationAndSeparateDives() async throws {
        let url = location()
        let journal = ExpeditionJournal(url: url)
        let first = UUID(), second = UUID()
        for index in 0..<235 { journal.record(entry(first, index, kind: index == 3 ? "boost" : "snapshot")) }
        journal.record(entry(first, 236, kind: "finish"))
        journal.record(entry(second, 300, kind: "start"))
        let receipts = try await journal.receipts()
        XCTAssertEqual(receipts.map(\.id), [second, first])
        XCTAssertEqual(receipts[1].boosts, 1)
        XCTAssertTrue(receipts[0].outcome.contains("Дело не закрыто"))
        let reopened = ExpeditionJournal(url: url)
        let page1 = try await reopened.entries(diveID: first)
        let page2 = try await reopened.entries(diveID: first, offset: 200)
        XCTAssertEqual(page1.count, 200)
        XCTAssertEqual(page2.count, 36)
        XCTAssertEqual(page1[3].boat.energy, 93)
        XCTAssertEqual(page2.last?.kind, "finish")
        XCTAssertEqual((page1 + page2).map(\.elapsed), (0..<235).map(Double.init) + [236])
    }

    func testWriteFailureIsReportedAndRetriedWithoutDuplicates() async throws {
        let url = location()
        let parent = url.deletingLastPathComponent()
        try Data("blocks directory creation".utf8).write(to: parent)
        let journal = ExpeditionJournal(url: url)
        let event = entry(UUID(), 0, kind: "finish")
        journal.record(event)
        do {
            _ = try await journal.receipts()
            XCTFail("Storage failure must be visible")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        try FileManager.default.removeItem(at: parent)
        let restored = try await journal.entries(diveID: event.diveID)
        XCTAssertEqual(restored.map(\.id), [event.id], "Recovery must not require resubmission")
        journal.record(event)
        let receipts = try await journal.receipts()
        XCTAssertEqual(receipts.count, 1)
        let entries = try await journal.entries(diveID: event.diveID)
        XCTAssertEqual(entries.count, 1)
    }

    func testEngineRecordsPostCostStateSnapshotsPauseAndAbandonment() async throws {
        let journal = ExpeditionJournal(url: location())
        let suite = "BureauTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let level = OceanLevel(size: CGSize(width: 1560, height: 2600), spawn: CGPoint(x: 300, y: 300),
            base: CGPoint(x: 180, y: 200), wreck: CGPoint(x: 1370, y: 2330))
        let engine = GameEngine(defaults: defaults, level: level, journal: journal, randomValue: { 1 })
        engine.startGame()
        let id = try XCTUnwrap(engine.diveID)
        engine.activateBoost()
        engine.activateBoost()
        engine.step(deltaTime: .nan)
        for _ in 0..<660 { engine.step(deltaTime: 1.0 / 120) }
        engine.pause()
        engine.returnToMenu()
        engine.startGame()
        XCTAssertNotEqual(engine.diveID, id)
        let entries = try await journal.entries(diveID: id)
        XCTAssertEqual(entries.filter { $0.kind == "boost" }.count, 1)
        XCTAssertEqual(entries.first { $0.kind == "boost" }?.boat.energy, 93)
        XCTAssertTrue(entries.contains { $0.kind == "ability.rejected" })
        XCTAssertTrue(entries.contains { $0.kind == "simulation.invalidDelta" && $0.severity == "error" })
        XCTAssertTrue(entries.contains { $0.kind == "snapshot" })
        XCTAssertTrue(entries.contains { $0.boat.state == "paused" })
        XCTAssertEqual(entries.filter { $0.kind == "finish" }.count, 1)
        XCTAssertTrue(entries.last?.message.contains("прервана") == true)
    }
}

private struct DiscardJournal: ExpeditionLogging {
    func record(_ entry: JournalEntry) {}
    func flush() {}
}

@MainActor
final class CaptainLoggerTests: XCTestCase {
    private func journalURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.json")
    }

    func testSobrietyAndPersistentReading() async throws {
        let url = journalURL()
        let logger = CaptainLogger(url: url)
        let expedition = UUID()
        for sobriety in CaptainLogger.Sobriety.allCases {
            logger.record("damage", message: "Корпус повреждён", expedition: expedition,
                          sobriety: sobriety, details: ["hull": "2", "depth": "150"])
        }
        let result = await logger.read()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertTrue(result.entries[0].message.contains("нелегка служба на подлодке"))
        XCTAssertEqual(result.entries[0].details, ["hull": "2"])
        XCTAssertEqual(result.entries[1].sobriety, .tipsy)
        XCTAssertTrue(result.entries[1].message.hasPrefix("Так, записываю…"))
        XCTAssertEqual(result.entries[1].details, ["hull": "2"])
        XCTAssertEqual(result.entries[2].details["depth"], "150")
        let reopened = await CaptainLogger(url: url).read()
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.entries.map(\.id), result.entries.map(\.id))
        XCTAssertTrue(reopened.entries.allSatisfy { $0.expedition == expedition })
    }

    func testRetentionKeepsNewestEntries() async {
        let logger = CaptainLogger(url: journalURL(), capacity: 2)
        for index in 0..<5 {
            logger.record(String(index), message: "Запись", expedition: UUID(), sobriety: .sober)
        }
        let result = await logger.read()
        XCTAssertEqual(result.entries.map(\.event), ["4", "3"])
        XCTAssertNil(result.error)
    }

    func testCorruptJournalIsNotOverwritten() async throws {
        let url = journalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged journal".utf8)
        try original.write(to: url)
        let logger = CaptainLogger(url: url)
        logger.record("new", message: "Новая запись", expedition: UUID(), sobriety: .sober)
        let result = await logger.read()
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWriteErrorIsReadable() async throws {
        let url = journalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        let logger = CaptainLogger(url: url.appendingPathComponent("impossible.json"))
        logger.record("test", message: "Запись", expedition: UUID(), sobriety: .sober)
        let result = await logger.read()
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.entries.count, 1)
    }

    func testEngineLogsFlowAndSeparatesExpeditions() async {
        let logger = CaptainLogger(url: journalURL())
        let engine = GameEngine(captainLogger: logger, randomValue: { 1 })
        engine.startGame()
        engine.activateBoost()
        engine.activateBoost()
        engine.pause()
        engine.togglePause()
        engine.startGame()
        let result = await logger.read()
        XCTAssertTrue(result.entries.contains { $0.event == "boost" })
        XCTAssertTrue(result.entries.contains { $0.event == "rejected.boost" })
        XCTAssertTrue(result.entries.contains { $0.event == "state" && $0.message.contains("paused") })
        XCTAssertEqual(Set(result.entries.map(\.expedition)).count, 2)
    }
}

@MainActor
final class DayTwoIntegrationTests: XCTestCase {
    func testRestartSeparatesArchivesAndPauseUsesSimulationTime() async throws {
        // given: all persistent views observe the same game, with isolated stores.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let receipt = ExpeditionJournal(url: root.appendingPathComponent("receipts.sqlite"))
        let captain = CaptainLogger(url: root.appendingPathComponent("captain.json"))
        let telemetryPath = root.appendingPathComponent("events.sqlite").path
        let telemetry = ExpeditionLogger(path: telemetryPath)
        let store = BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let logger = BlackBox(store: store)
        let engine = GameEngine(telemetryLogger: telemetry, journal: receipt, captainLogger: captain,
                                randomValue: { 1 })
        let recorder = BlackBoxRecorder(engine: engine, logger: logger)

        // when: restart directly from playing, then leave the second run twice.
        engine.startGame()
        let first = try XCTUnwrap(engine.diveID)
        engine.activateBoost()
        for _ in 0..<20 { engine.step(deltaTime: 0.1) }
        engine.pauseForScreen("Map")
        let pausedTime = recorder.timestamp().1
        for _ in 0..<20 { engine.step(deltaTime: 0.1) }
        XCTAssertEqual(recorder.timestamp().1, pausedTime)
        engine.navigate(to: "Pause", reason: "closeMap")
        engine.navigate(to: "Journal", reason: "openJournal")
        engine.navigate(to: "Pause", reason: "closeJournal")
        engine.togglePause()
        engine.startGame()
        let second = try XCTUnwrap(engine.diveID)
        engine.activateSonar()
        engine.returnToMenu()
        engine.returnToMenu()
        await engine.flushJournal()
        await recorder.drain()

        // then: immutable run identity and exactly one boundary per run in each event store.
        XCTAssertNotEqual(first, second)
        let blackBox = try await BlackBoxReader(store: store).all()
        for id in [first, second] {
            let events = blackBox.filter { $0.runID == id }
            XCTAssertEqual(events.filter { $0.message == "run.start" }.count, 1)
            XCTAssertEqual(events.filter { $0.message == "run.end" }.count, 1)
            XCTAssertEqual(events.first?.t, 0)
            let receiptEvents = try await receipt.entries(diveID: id)
            XCTAssertEqual(receiptEvents.filter { $0.kind == "start" }.count, 1)
            XCTAssertEqual(receiptEvents.filter { $0.kind == "finish" }.count, 1)
            let telemetryEvents = try await LogReader(path: telemetryPath).events(expeditionId: id.uuidString)
            XCTAssertEqual(telemetryEvents.filter { $0.type == "start" }.count, 1)
            XCTAssertEqual(telemetryEvents.filter { $0.type == "end" }.count, 1)
            if id == first {
                XCTAssertTrue(telemetryEvents.contains { $0.type == "boost" })
                XCTAssertFalse(telemetryEvents.contains { $0.type == "sonar" })
            } else {
                XCTAssertTrue(telemetryEvents.contains { $0.type == "sonar" })
                XCTAssertFalse(telemetryEvents.contains { $0.type == "boost" })
            }
        }
        let watched = await captain.read()
        XCTAssertEqual(Set(watched.entries.map(\.expedition)), [first, second])
        let transitions = try await LogReader(path: telemetryPath).transitions(expeditionId: first.uuidString)
        XCTAssertTrue(transitions.contains { $0.from == "Map" && $0.to == "Pause" })
        XCTAssertTrue(transitions.contains { $0.from == "Pause" && $0.to == "Journal" })
        XCTAssertTrue(transitions.contains { $0.from == "Journal" && $0.to == "Pause" })
    }

    func testDiagnosticPersistsWithoutSpeakingAndOldVoiceCallbacksCannotOverwriteNewNote() async throws {
        // given
        final class Transcriber: VoiceNoteTranscriber {
            var updates: [@MainActor (String) -> Void] = []
            var failures: [@MainActor (String) -> Void] = []
            func start(update: @escaping @MainActor (String) -> Void,
                       failure: @escaping @MainActor (String) -> Void) async throws { updates.append(update); failures.append(failure) }
            func stop() {}
        }
        let store = BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let engine = GameEngine(randomValue: { 1 })
        let recorder = BlackBoxRecorder(engine: engine, logger: BlackBox(store: store))
        engine.startGame()
        var spoken: [String] = []
        let announcer = VoiceOverAnnouncer(engine: engine, voiceOverRunning: { true },
                                           post: { spoken.append($0.string) })
        let transcriber = Transcriber()
        let note = CaptainNote(transcriber: transcriber)

        // when: callbacks from a cancelled recognition session arrive during the next session.
        engine.events.send(.diagnostic(.warning, .system, "test.diagnostic", [:]))
        await note.toggle(recorder: recorder)
        transcriber.updates[0]("Первая заметка")
        note.finish(recorder: recorder)
        await note.toggle(recorder: recorder)
        transcriber.updates[1]("Вторая заметка")
        transcriber.updates[0]("Запоздалый результат")
        transcriber.failures[0]("Запоздалая ошибка")
        XCTAssertTrue(note.recording)
        XCTAssertNil(note.error)
        note.finish(recorder: recorder)
        await recorder.drain()

        // then
        XCTAssertTrue(spoken.isEmpty)
        let entries = try await BlackBoxReader(store: store).all()
        XCTAssertEqual(entries.filter { $0.message == "test.diagnostic" }.count, 1)
        XCTAssertEqual(entries.filter { $0.category == .captain }.map(\.message), ["Первая заметка", "Вторая заметка"])
        withExtendedLifetime(announcer) {}
    }
}

extension BlackBoxTests {
    func testUnavailableStoreRetriesAndRebasesBufferedEventsAfterPersistedSequence() async throws {
        // given: a previous launch already used sequence 40; this launch initially cannot open the store.
        final class Availability: @unchecked Sendable {
            private let lock = NSLock()
            private var ready = false
            func allow() { lock.withLock { ready = true } }
            func check() throws {
                try lock.withLock {
                    if !ready { throw CocoaError(.fileReadNoPermission) }
                }
            }
        }
        let store = try store(), id = UUID()
        let start = BlackBoxEntry(runID: id, seq: 39, t: 0, wallTime: Date(), level: .info,
                                 category: .state, message: "run.start", attrs: [:])
        let end = BlackBoxEntry(runID: id, seq: 40, t: 0, wallTime: Date(), level: .info,
                               category: .state, message: "run.end", attrs: [:])
        try await store.write([start, end])
        let availability = Availability()
        let logger = BlackBox(sleep: { throw CancellationError() }, storeFactory: {
            try availability.check()
            return store
        })

        // when: retry without resubmitting the event that was buffered while opening failed.
        await logger.log(.info, .event, "buffered", runID: id, t: 1)
        let failure = await logger.storageError
        XCTAssertNotNil(failure)
        availability.allow()
        await logger.flush()
        await logger.log(.info, .event, "new", runID: id, t: 2)
        await logger.flush()

        // then: no silent success, lost event, or duplicate sequence at the read cursor.
        let entries = try await BlackBoxReader(store: store).all(runID: id)
        XCTAssertEqual(entries.map(\.message), ["run.start", "run.end", "buffered", "new"])
        XCTAssertEqual(entries.map(\.seq), [39, 40, 41, 42])
        let recovered = await logger.storageError
        XCTAssertNil(recovered)
    }
}

@MainActor
private final class MemoryReminders: ReminderClient {
    var allowed = true
    var requests: [String: UNNotificationRequest] = [:]
    func authorize() async throws -> Bool { allowed }
    func replace(_ requests: [UNNotificationRequest]) async throws {
        self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
    }
    func cancel() { requests = [:] }
}

@MainActor
final class ExpeditionRecoveryTests: XCTestCase {
    private func fixture() -> (GameEngine, ExpeditionRecovery, MemoryReminders, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let engine = GameEngine(defaults: defaults, journal: DiscardJournal(), randomValue: { 0 })
        let client = MemoryReminders()
        let recovery = ExpeditionRecovery(engine: engine, directory: directory, client: client,
                                           now: { Date(timeIntervalSince1970: 1_773_000_000) })
        engine.recovery = recovery
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (engine, recovery, client, directory)
    }
    func testExactSnapshotAndPausedRestore() throws {
        let (engine, recovery, _, _) = fixture()
        engine.startGame(); engine.setSteering(CGVector(dx: 0.6, dy: 0.8)); engine.activateBoost()
        for _ in 0..<120 { engine.step(deltaTime: 1.0 / 120) }
        let before = engine.snapshot()
        engine.returnToMenu()
        recovery.open(ReturnRoute(id: before.id).url)
        XCTAssertEqual(engine.state, .paused)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try JSONSerialization.jsonObject(with: encoder.encode(before)) as! NSDictionary
        let restored = try JSONSerialization.jsonObject(with: encoder.encode(engine.snapshot())) as! NSDictionary
        for key in original.allKeys where key as? String != "revealedPickups" { XCTAssertEqual(original[key] as? NSObject, restored[key] as? NSObject, "Snapshot field: \(key)") }
        XCTAssertEqual(before.revealedPickups, engine.revealedPickups)
        engine.togglePause()
        for _ in 0..<60 { engine.step(deltaTime: 1.0 / 120) }
        let position = engine.position
        recovery.open(ReturnRoute(id: before.id).url)
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.position, position)
        XCTAssertEqual(recovery.history.filter { $0.kind == "restore" }.count, 1)
    }
    func testScheduleCancelRescheduleAndPushRoute() async throws {
        let (engine, recovery, client, _) = fixture()
        engine.startGame(); engine.pause()
        await recovery.settle()
        XCTAssertTrue(client.requests.isEmpty)
        engine.returnToMenu(); await recovery.settle()
        XCTAssertEqual(client.requests.count, 2)
        let request = try XCTUnwrap(client.requests["expedition.return.7"])
        let url = try XCTUnwrap(URL(string: request.content.userInfo["url"] as! String))
        let eventID = UUID(uuidString: request.content.userInfo["eventID"] as! String)!
        recovery.open(url, pushEventID: eventID); await recovery.settle()
        XCTAssertEqual(engine.state, .paused); XCTAssertTrue(client.requests.isEmpty)
        recovery.open(url, pushEventID: eventID)
        XCTAssertEqual(recovery.history.filter { $0.kind == "pushOpened" }.count, 1)
        engine.togglePause(); engine.returnToMenu(); await recovery.settle()
        XCTAssertEqual(client.requests.count, 2)
        recovery.deleteSave(); await recovery.settle()
        XCTAssertTrue(client.requests.isEmpty)
        recovery.open(url); XCTAssertNotNil(recovery.message); XCTAssertEqual(engine.state, .ready)
    }
    func testCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 14, minute: 30))!
        let requests = ReminderPlan.requests(id: UUID(), eventID: UUID(), now: now, calendar: calendar)
        for (index, day) in [8, 14].enumerated() {
            let trigger = try XCTUnwrap(requests[index].trigger as? UNCalendarNotificationTrigger)
            XCTAssertEqual(trigger.dateComponents.day, day)
            XCTAssertEqual(trigger.dateComponents.hour, 14)
            XCTAssertEqual(trigger.dateComponents.minute, 30)
            XCTAssertFalse(trigger.repeats)
        }
    }
    func testColdStartHistoryFiltersAndDeniedPermission() async throws {
        let (engine, recovery, client, directory) = fixture()
        client.allowed = false
        engine.startGame(); engine.returnToMenu(); await recovery.settle()
        XCTAssertTrue(client.requests.isEmpty)
        let id = try XCTUnwrap(recovery.savedID)
        let second = GameEngine(journal: DiscardJournal())
        let restored = ExpeditionRecovery(engine: second, directory: directory, client: client)
        second.recovery = restored
        let inbox = ReturnInbox()
        inbox.receive(ReturnRoute(id: id).url)
        XCTAssertEqual(second.state, .ready)
        inbox.connect { url, _ in restored.open(url) }
        XCTAssertEqual(second.state, .paused)
        let event = try XCTUnwrap(restored.events(.unread).first)
        restored.markRead(event.id)
        XCTAssertFalse(restored.events(.unread).contains { $0.id == event.id })
        XCTAssertTrue(restored.events(.notifications).allSatisfy(\.isNotification))
        let reloaded = ExpeditionRecovery(engine: second, directory: directory, client: client)
        XCTAssertTrue(reloaded.history.contains { $0.id == event.id && $0.read })
        restored.deleteSave()
        XCTAssertFalse(restored.canOpen(event))
        XCTAssertFalse(restored.history.isEmpty)
    }
    func testVersionCorruptionStaleAndConfirmation() throws {
        let (engine, recovery, _, directory) = fixture()
        engine.startGame(); engine.pause()
        let save = try recovery.load()
        let stale = ReturnRoute(id: UUID()).url
        recovery.open(stale); XCTAssertEqual(engine.state, .paused); XCTAssertNotNil(recovery.message)
        var other = save; other.id = UUID()
        try JSONEncoder().encode(other).write(to: directory.appendingPathComponent("expedition.json"))
        recovery.open(ReturnRoute(id: other.id).url)
        XCTAssertNotNil(recovery.replacement); XCTAssertEqual(engine.expeditionId, save.id.uuidString)
        recovery.open(ReturnRoute(id: other.id).url, confirmed: true)
        XCTAssertEqual(engine.expeditionId, other.id.uuidString)
        var incompatible = save; incompatible.version = 99
        try JSONEncoder().encode(incompatible).write(to: directory.appendingPathComponent("expedition.json"))
        XCTAssertThrowsError(try recovery.load())
        try Data("broken".utf8).write(to: directory.appendingPathComponent("expedition.json"))
        XCTAssertThrowsError(try recovery.load())
        let reload = ExpeditionRecovery(engine: GameEngine(journal: DiscardJournal()), directory: directory, client: MemoryReminders())
        XCTAssertNil(reload.savedID); XCTAssertNotNil(reload.message)
    }
}

extension ExpeditionRecoveryTests {
    func testTerminalRunDeletesSaveAndInvalidatesEvents() async throws {
        let (engine, recovery, client, _) = fixture()
        engine.startGame(); engine.pause()
        let id = try XCTUnwrap(recovery.savedID)
        var ending = try recovery.load()
        ending.energy = 0.001
        ending.position = CGPoint(x: 700, y: 300)
        engine.restore(ending)
        engine.togglePause()
        engine.setSteering(CGVector(dx: 1, dy: 0))
        engine.step(deltaTime: 0.1)
        XCTAssertEqual(engine.state, .gameOver)
        XCTAssertNil(recovery.savedID)
        XCTAssertTrue(recovery.history.contains { $0.kind == "gameOver" })
        XCTAssertTrue(recovery.history.allSatisfy { !recovery.canOpen($0) })
        recovery.open(ReturnRoute(id: id).url)
        XCTAssertEqual(engine.state, .ready)
        await recovery.settle()
        XCTAssertTrue(client.requests.isEmpty)
    }
    func testOutOfRangeNumbersAreRejectedBeforeRestore() throws {
        let (engine, recovery, _, directory) = fixture()
        engine.startGame(); engine.pause()
        var snapshot = try recovery.load()
        snapshot.position = CGPoint(x: 1e100, y: 1e100)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("expedition.json"))
        XCTAssertThrowsError(try recovery.load())
    }
}


extension ExpeditionRecoveryTests {
    func testResumePreservesPartialPhysicsStep() {
        let (reference, _, _, _) = fixture()
        reference.startGame()
        reference.setSteering(CGVector(dx: 1, dy: 0))
        reference.step(deltaTime: 0.014)
        let resumed = GameEngine(journal: DiscardJournal())
        resumed.restore(reference.snapshot())
        resumed.togglePause()
        reference.step(deltaTime: 0.020)
        resumed.step(deltaTime: 0.020)
        XCTAssertEqual(reference.position, resumed.position)
        XCTAssertEqual(reference.velocity, resumed.velocity)
        XCTAssertEqual(reference.energy, resumed.energy)
        XCTAssertEqual(reference.runElapsed, resumed.runElapsed)
    }
}
