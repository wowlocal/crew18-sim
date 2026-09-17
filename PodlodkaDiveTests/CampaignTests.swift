import Combine
import SwiftData
import XCTest

@testable import PodlodkaDive

@MainActor
final class CampaignTests: XCTestCase {
  private func storage() -> UserDefaults {
    let name = "CampaignTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return defaults
  }
  private func engine(
    _ mission: CampaignMission, secret: Double = 0.99,
    defaults: UserDefaults? = nil, portal: Bool = false
  ) -> GameEngine {
    let defaults = defaults ?? storage()
    var progress = CampaignProgress()
    if mission != .aster { progress.completed.insert(.aster) }
    if mission == .silentSignal { progress.completed.insert(.currentStation) }
    progress.selected = mission
    progress.save(to: defaults)
    var values =
      mission == .silentSignal ? [secret, portal ? 0.0 : 1.0, 0.0] : [portal ? 0.0 : 1.0, 0.0]
    let game = GameEngine(
      defaults: defaults, randomValue: { values.isEmpty ? 1 : values.removeFirst() })
    game.startGame()
    return game
  }
  private func sail(_ game: GameEngine, _ points: [(CGFloat, CGFloat)]) {
    GameTestPilot.navigate(game, through: points.map { CGPoint(x: $0.0, y: $0.1) })
  }
  private func tick(_ game: GameEngine, _ seconds: Double = 0.5) {
    GameTestPilot.advance(game, seconds)
  }
  private func stationOutbound(_ game: GameEngine) {
    sail(game, [(440, 370), (1200, 370), (1200, 1640), (1340, 1720), (1360, 1910)])
  }
  private func stationHome(_ game: GameEngine) {
    sail(game, [(1360, 2100), (390, 2100), (360, 1540), (360, 650), (300, 400), (200, 230)])
  }
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testProgressMigrationSelectionAndRecoveryPreserveGarage() throws {
    // given
    let defaults = storage()
    let fresh = GameEngine(defaults: defaults, randomValue: { 1 })
    XCTAssertFalse(fresh.selectMission(.currentStation))
    defaults.removeObject(forKey: CampaignProgress.storageKey)
    defaults.set(825, forKey: CampaignProgress.legacyBestKey)
    let garage = Data("legacy garage bytes".utf8)
    defaults.set(garage, forKey: "podlodkaDive.garage.v1")

    // when
    let migrated = GameEngine(defaults: defaults, randomValue: { 1 })
    XCTAssertEqual(migrated.bestScore, 825)
    XCTAssertTrue(migrated.selectMission(.currentStation))
    XCTAssertEqual(migrated.bestScore, 0)
    migrated.startGame()
    XCTAssertFalse(migrated.selectMission(.aster))
    migrated.pause()
    XCTAssertFalse(migrated.selectMission(.aster))
    migrated.returnToMenu()
    let restored = GameEngine(defaults: defaults, randomValue: { 1 })

    // then
    XCTAssertEqual(restored.mission, .currentStation)
    XCTAssertEqual(restored.campaignProgress.completed, [.aster])
    XCTAssertFalse(restored.selectMission(.silentSignal))
    defaults.set(Data("broken".utf8), forKey: CampaignProgress.storageKey)
    let recovered = GameEngine(defaults: defaults)
    XCTAssertEqual(recovered.mission, .aster)
    XCTAssertTrue(recovered.campaignProgress.completed.isEmpty)
    XCTAssertEqual(defaults.data(forKey: "podlodkaDive.garage.v1"), garage)
    XCTAssertEqual(defaults.integer(forKey: CampaignProgress.legacyBestKey), 825)
  }

  func testStationCircuitCompletesOnlyAtHomeAndPersists() {
    // given
    let defaults = storage()
    let game = engine(.currentStation, defaults: defaults)
    var ends: [String] = []
    let subscription = game.events.sink {
      if case .runEnded(let outcome) = $0 { ends.append(outcome) }
    }
    defer { subscription.cancel() }
    let currency = game.crystals

    // when: completing the objective on the way overrides an earlier retreat decision.
    game.setReturnToBase(true)
    stationOutbound(game)

    // then: station hands over equipment, not a black box or a finished expedition.
    XCTAssertTrue(game.objectiveReady)
    XCTAssertFalse(game.hasBlackBox)
    XCTAssertEqual(game.state, .playing)
    XCTAssertFalse(game.campaignProgress.isUnlocked(.silentSignal))
    XCTAssertEqual(game.target, game.level.base)
    stationHome(game)
    XCTAssertEqual(game.outcome, .completed)
    XCTAssertEqual(game.hull, 3)
    XCTAssertGreaterThanOrEqual(game.energy, 20)
    XCTAssertGreaterThanOrEqual(game.score, 600)
    XCTAssertEqual(ends, [ExpeditionOutcome.completed.rawValue])
    let earned = game.crystals
    tick(game, 5)
    XCTAssertEqual(game.crystals, earned)
    XCTAssertGreaterThanOrEqual(earned, currency)
    let restored = GameEngine(defaults: defaults)
    XCTAssertTrue(restored.campaignProgress.isUnlocked(.silentSignal))
    XCTAssertEqual(restored.bestScore, game.score)
    print(
      "Campaign station ring: \(game.runElapsed)s, \(game.energy) energy, \(game.score) salvage")
    game.startGame()
    sail(game, [(440, 340), (1200, 340), (1200, 1640), (1340, 1720), (1360, 1910)])
    stationHome(game)
    XCTAssertEqual(game.outcome, .completed)
    XCTAssertLessThan(
      game.score, restored.bestScore, "Replay deliberately skips the sample north of the current")
    XCTAssertEqual(
      GameEngine(defaults: defaults).bestScore, restored.bestScore,
      "A lower successful replay must not replace the mission record")
  }

  func testReturnAgainstCurrentCostsMoreThanWesternLoop() {
    // given
    let west = engine(.currentStation)
    let east = engine(.currentStation)
    stationOutbound(west)
    stationOutbound(east)
    let startTime = west.runElapsed

    // when
    stationHome(west)
    sail(east, [(1340, 1720), (1200, 1640), (1200, 370), (440, 370), (200, 230)])

    // then
    XCTAssertEqual(east.outcome, .completed)
    XCTAssertEqual(east.hull, 3)
    XCTAssertGreaterThan(east.runElapsed - startTime, west.runElapsed - startTime)
    XCTAssertGreaterThan(west.energy, east.energy)
    print(
      "Campaign return: west \(west.runElapsed-startTime)s/\(west.energy) energy, east \(east.runElapsed-startTime)s/\(east.energy) energy"
    )
  }

  func testSearchDoesNotRevealTruthUntilNearbySonarAcrossAllTargets() {
    // given: the random true signal must not affect any public target before a scan.
    let games = [0.0, 0.5, 0.99].map { engine(.silentSignal, secret: $0) }
    let first = games[0]
    let initialOverview = first.sectorOverview
    let initialContacts = first.sonarContacts
    for game in games {
      XCTAssertEqual(game.target, first.target)
      XCTAssertEqual(game.targetLabel, first.targetLabel)
      XCTAssertEqual(game.sectorOverview, initialOverview)
      XCTAssertEqual(game.sonarContacts, initialContacts)
      XCTAssertEqual(game.missionRun?.signals, first.missionRun?.signals)
      XCTAssertFalse(game.pickups.contains { $0.kind == .blackBox })
      game.activateSonar()
      XCTAssertEqual(game.missionRun?.checkedCount, 0)
    }

    for (index, game) in games.enumerated() {
      // when
      sail(game, [(350, 380), (280, 850)])
      XCTAssertFalse(
        game.objectiveReady, "Approaching a true signal without sonar must not collect it")
      game.activateSonar()
      tick(game)
      if index == 0 {
        XCTAssertTrue(game.objectiveReady)
        XCTAssertEqual(game.missionRun?.checkedCount, 1)
        sail(game, [(350, 380), (780, 230)])
      } else {
        XCTAssertEqual(game.missionRun?.signals[0].finding, .buoy)
        sail(game, [(330, 1080), (790, 1160), (1270, 1060)])
        game.activateSonar()
        tick(game)
        if index == 1 {
          XCTAssertTrue(game.objectiveReady)
          sail(game, [(790, 1160), (350, 1040), (350, 380), (780, 230)])
        } else {
          sail(game, [(1330, 1480), (1330, 1860), (780, 1950)])
          game.activateSonar()
          tick(game)
          sail(game, [(780, 1780), (780, 1040), (350, 1040), (350, 380), (780, 230)])
        }
      }
      // then
      XCTAssertEqual(game.outcome, .completed, "Target \(index)")
      XCTAssertFalse(game.hasBlackBox)
      XCTAssertEqual(game.hull, 3)
      XCTAssertGreaterThanOrEqual(game.energy, 15)
      XCTAssertTrue(game.campaignProgress.completed.contains(.silentSignal))
      print("Campaign search \(index): \(game.runElapsed)s, \(game.energy) energy")
    }
  }

  func testEarlyReturnPreservesOnlyRecoveredCargoAndCanBeCancelled() {
    // given
    let game = engine(.silentSignal)
    sail(game, [(780, 230)])
    XCTAssertLessThan(
      hypot(game.position.x - game.level.base.x, game.position.y - game.level.base.y), 68)
    tick(game, 2)
    XCTAssertEqual(
      game.state, .playing, "Docking without a goal or return intent must not end the trip")
    sail(game, [(350, 380), (300, 700)])
    XCTAssertGreaterThan(game.samples, 0)
    let cargo = game.cargoValue
    let position = game.position
    let time = game.runElapsed

    // when
    game.pause()
    game.setReturnToBase(true)
    XCTAssertEqual(game.target, game.level.base)
    tick(game, 20)
    XCTAssertEqual(game.runElapsed, time)
    XCTAssertEqual(game.position, position)
    XCTAssertEqual(game.state, .paused)
    game.setReturnToBase(false)
    XCTAssertNotEqual(game.target, game.level.base)
    XCTAssertEqual(game.cargoValue, cargo)
    game.setReturnToBase(true)
    game.togglePause()
    sail(game, [(350, 380), (780, 230)])

    // then
    XCTAssertEqual(game.outcome, .returned)
    XCTAssertEqual(game.score, cargo)
    XCTAssertEqual(game.bestScore, 0)
    XCTAssertFalse(game.campaignProgress.completed.contains(.silentSignal))
    XCTAssertTrue(game.resultDetail.contains("не выполнено"))
  }

  func testStationContactRequiresSlowLiveSimulation() {
    // given
    let game = engine(.currentStation)
    sail(game, [(440, 370), (1200, 370), (1200, 1640), (1340, 1720), (1360, 1780)])
    game.setSteering(CGVector(dx: 0, dy: 1))
    for _ in 0..<100 where game.position.y < 1880 && game.state == .playing { tick(game, 0.1) }
    XCTAssertGreaterThanOrEqual(game.speed, 48)
    XCTAssertFalse(game.objectiveReady)
    game.pause()
    let energy = game.energy
    let position = game.position

    // when
    tick(game, 15)

    // then
    XCTAssertFalse(game.objectiveReady)
    XCTAssertEqual(game.energy, energy)
    XCTAssertEqual(game.position, position)
    game.togglePause()
    game.setSteering(.zero)
    tick(game)
    XCTAssertTrue(game.objectiveReady)
    XCTAssertLessThanOrEqual(game.energy, energy, "Station does not refill energy")
    game.returnToMenu()
    XCTAssertEqual(game.outcome, .abandoned)
    XCTAssertFalse(game.campaignProgress.completed.contains(.currentStation))
    game.startGame()
    XCTAssertFalse(game.objectiveReady)
  }
}

extension CampaignTests {
  fileprivate func allEvents(_ reader: LogReader, id: UUID) async throws -> [ExpeditionEvent] {
    var events: [ExpeditionEvent] = []
    while true {
      let page = try await reader.events(
        expeditionId: id.uuidString, after: events.last?.sequenceNumber ?? 0, limit: 1000)
      events += page
      if page.count < 1000 { return events }
    }
  }
}

extension CampaignTests {
  func testActivePulseScansOnApproachAndPauseFreezesIt() {
    // given
    let game = engine(.silentSignal, secret: 0)
    sail(game, [(350, 380), (280, 560)])
    var checks = 0
    let subscription = game.events.sink {
      if case .diagnostic(_, _, "signal.checked", _) = $0 { checks += 1 }
    }
    defer { subscription.cancel() }
    game.activateSonar()
    XCTAssertEqual(game.missionRun?.checkedCount, 0)
    game.pause()
    let pulse = game.sonarRemaining

    // when
    tick(game, 20)
    XCTAssertEqual(game.sonarRemaining, pulse)
    game.togglePause()
    sail(game, [(280, 680)])
    XCTAssertEqual(game.missionRun?.foundDrone?.id, 0)
    XCTAssertFalse(
      game.objectiveReady, "Identifying a signal 170 units away must not recover the drone")
    sail(game, [(280, 850)])

    // then: moving into an active pulse identifies and recovers the drone once.
    XCTAssertTrue(game.objectiveReady)
    XCTAssertEqual(checks, 1)
    XCTAssertFalse(game.sonarContacts.contains { $0.id == "signal-0" })
    XCTAssertEqual(game.missionLandmarks.first?.kind, .recovered)
    let recoveredCargo = game.cargoValue
    tick(game, 9)
    game.activateSonar()
    tick(game)
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(game.cargoValue, recoveredCargo)
  }

  func testCavePreservesMissionState() throws {
    // given
    let game = engine(.silentSignal, portal: true)
    sail(game, [(350, 380), (280, 850)])
    game.activateSonar()
    XCTAssertEqual(game.missionRun?.signals[0].finding, .buoy)
    game.setReturnToBase(true)
    let signals = try XCTUnwrap(game.missionRun?.signals)
    let portal = try XCTUnwrap(game.portal)

    // when
    sail(game, [(330, 1080), (portal.position.x, portal.position.y)])
    XCTAssertEqual(game.zone, .bossCave)
    game.setReturnToBase(false)
    XCTAssertEqual(
      game.missionRun?.returningEarly, true, "Cave cannot be escaped by changing mission course")
    _ = GameTestPilot.surviveCave(game)

    // then
    XCTAssertEqual(game.state, .playing)
    XCTAssertEqual(game.zone, .ocean)
    XCTAssertTrue(game.bossDefeated)
    XCTAssertEqual(game.missionRun?.signals, signals)
    XCTAssertEqual(game.target, game.level.base)
    XCTAssertFalse(game.objectiveReady)
    XCTAssertFalse(game.campaignProgress.completed.contains(.silentSignal))
  }

  func testMissionTransitionsReachExistingArchivesWithoutSecretCoordinates() async throws {
    // given: real stores, one recorder, shared run identity.
    let directory = try temporaryDirectory()
    let receipt = ExpeditionJournal(url: directory.appendingPathComponent("receipts.sqlite"))
    let watch = CaptainLogger(url: directory.appendingPathComponent("watch.json"))
    let path = directory.appendingPathComponent("telemetry.sqlite").path
    let telemetry = ExpeditionLogger(path: path)
    let store = BlackBoxStore(
      modelContainer: try ModelContainer(
        for: BlackBoxRow.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    let defaults = storage()
    var progress = CampaignProgress()
    progress.completed = [.aster]
    progress.selected = .currentStation
    progress.save(to: defaults)
    let game = GameEngine(
      defaults: defaults, telemetryLogger: telemetry, journal: receipt,
      captainLogger: watch, randomValue: { 1 })
    let recorder = BlackBoxRecorder(engine: game, logger: BlackBox(store: store))
    game.startGame()
    let first = try XCTUnwrap(game.diveID)

    // when: finish delivery, change mission, then return from search without a scan.
    stationOutbound(game)
    stationHome(game)
    await game.flushJournal()
    let reader = LogReader(path: path)
    let original = try await allEvents(reader, id: first)
    game.returnToMenu()
    XCTAssertTrue(game.selectMission(.silentSignal))
    game.navigate(to: "Campaign", reason: "openCampaign")
    game.navigate(to: "Welcome", reason: "closeCampaign")
    await game.flushJournal()
    let unchanged = try await allEvents(reader, id: first)
    XCTAssertEqual(
      unchanged.map(\.payload), original.map(\.payload),
      "Choosing a new map must not rewrite the old replay")
    game.startGame()
    let second = try XCTUnwrap(game.diveID)
    game.setReturnToBase(true)
    sail(game, [(780, 230)])
    await game.flushJournal()
    await recorder.drain()

    // then: each existing archive observes the same mission and precise terminal outcome.
    let deliveries = original.filter { $0.type == "equipment.delivered" }
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?.payload["missionID"], CampaignMission.currentStation.rawValue)
    XCTAssertEqual(original.last?.payload["result"], ExpeditionOutcome.completed.rawValue)
    XCTAssertFalse(original.contains { $0.type == "blackBox" })
    let partial = try await allEvents(reader, id: second)
    XCTAssertEqual(partial.last?.payload["result"], ExpeditionOutcome.returned.rawValue)
    let start = try XCTUnwrap(partial.first { $0.type == "start" })
    XCTAssertEqual(start.payload["missionID"], CampaignMission.silentSignal.rawValue)
    XCTAssertEqual(start.payload["signals"]?.components(separatedBy: "unknown").count, 4)
    XCTAssertFalse(start.payload.values.contains { $0.contains("drone") })
    XCTAssertFalse(start.payload["pickups"]?.contains("blackBox") ?? true)
    let receipts = try await receipt.receipts()
    XCTAssertEqual(
      receipts.first { $0.id == first }?.missionID, CampaignMission.currentStation.rawValue)
    XCTAssertEqual(receipts.first { $0.id == first }?.blackBoxes, 0)
    XCTAssertTrue(receipts.first { $0.id == second }?.outcome.contains("не выполнено") == true)
    let blackBox = try await BlackBoxReader(store: store).all()
    XCTAssertEqual(
      blackBox.filter { $0.runID == first && $0.message == "equipment.delivered" }.count, 1)
    XCTAssertEqual(
      blackBox.first { $0.runID == second && $0.message == "run.end" }?.attrs["outcome"],
      ExpeditionOutcome.returned.rawValue)
    let captain = await watch.read()
    XCTAssertTrue(
      captain.entries.contains { $0.expedition == first && $0.event == "equipment.delivered" })
    XCTAssertTrue(
      captain.entries.contains {
        $0.expedition == second && $0.event == ExpeditionOutcome.returned.rawValue
      })
    XCTAssertTrue(
      game.crewJournal.entries.contains {
        $0.message.contains("не выполнено") || $0.message.contains("без выполнения")
      })
  }
}
