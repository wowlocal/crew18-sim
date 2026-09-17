import XCTest
@testable import PodlodkaDive

final class ExpeditionLogTests: XCTestCase, @unchecked Sendable {
    private func path() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path }
    private func event(_ sequence: Int, _ type: String = "snapshot", _ time: Double = 0, _ payload: [String: String] = [:]) -> ExpeditionEvent {
        .init(expeditionId: "test", sequenceNumber: sequence, timestamp: Date(), schemaVersion: 1, category: "State", type: type, severity: "info", payload: payload.merging(["time": String(time)]) { _, new in new })
    }
    func testTransactionDeduplicationReopenAndInterrupted() throws {
        let file = path()
        do {
            let store = try LogStore(path: file)
            let events = [event(1, "start"), event(2, "snapshot", 9, ["cargo": "75"])]
            try store.batch(events); try store.batch(events)
            XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM events")[0][0], "2")
        }
        let reopened = try LogStore(path: file, recover: true)
        XCTAssertEqual(try reopened.rows("SELECT result,duration,cargo FROM expeditions")[0], ["interrupted", "9.0", "75"])
    }
    func testConcurrentStressBatchFlushAndPagination() async throws {
        let file = path()
        // Independent DB used below so the read connection can observe committed boundaries.
        let writer = ExpeditionLogger(path: file)
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5000 {
                group.addTask { await writer.log(expeditionId: "stress", type: "damage", payload: ["index": String(index)]) }
            }
        }
        await writer.flush()
        let reader = LogReader(path: file)
        var all: [ExpeditionEvent] = []
        while true {
            let page = try await reader.events(expeditionId: "stress", after: all.last?.sequenceNumber ?? 0, limit: 333)
            all += page
            if page.count < 333 { break }
        }
        XCTAssertEqual(all.count, 5000)
        XCTAssertEqual(all.map(\.sequenceNumber), Array(1...5000))
        XCTAssertEqual(Set(all.compactMap { $0.payload["index"] }).count, 5000)
        let batches = await writer.batchCount
        XCTAssertEqual(batches, 79)
        let error = await writer.lastError
        XCTAssertNil(error)
        print("Expedition stress: 5000 events, \(batches) batches, \(Date().timeIntervalSince(start)) seconds")
    }
    func testTimerAndEndFlush() async throws {
        let file = path()
        let logger = ExpeditionLogger(path: file)
        await logger.log(expeditionId: "timed", type: "start")
        try await Task.sleep(for: .milliseconds(2300))
        let reader = LogReader(path: file)
        let first = try await reader.events(expeditionId: "timed")
        XCTAssertEqual(first.count, 1)
        await logger.log(expeditionId: "timed", type: "end", payload: ["result": "completed", "cargo": "100", "time": "10"])
        let summaries = try await reader.expeditions()
        XCTAssertEqual(summaries.first?.result, "completed")
        XCTAssertEqual(summaries.first?.cargo, "100")
    }
    func testDatabaseFailureKeepsCriticalEventsAndDropsSnapshots() async {
        let logger = ExpeditionLogger(path: "/dev/null/journal.sqlite")
        for _ in 0..<600 { await logger.state(expeditionId: "broken", payload: [:]) }
        await logger.error(expeditionId: "broken", message: "critical")
        await logger.log(expeditionId: "broken", type: "end")
        await logger.flush()
        let error = await logger.lastError
        let dropped = await logger.droppedSnapshots
        XCTAssertNotNil(error)
        XCTAssertEqual(dropped, 88)
    }
    func testReplaySeekInterpolationZoneBoundaryAndHighlights() {
        let timeline = ReplayTimeline(events: [
            event(1, "start", 0, ["x": "0", "y": "10", "zone": "ocean", "hull": "3"]),
            event(2, "damage", 10, ["x": "100", "y": "30", "zone": "ocean", "hull": "2"]),
            event(3, "sonar", 11), event(4, "blackBox", 30), event(5, "docking", 50)
        ])
        XCTAssertEqual(Double(timeline.state(at: 5)["x"]!), 50)
        XCTAssertEqual(timeline.state(at: 5)["hull"], "3")
        XCTAssertEqual(timeline.state(at: 10)["hull"], "2")
        XCTAssertEqual(Double(timeline.state(at: -1)["x"]!), 0)
        XCTAssertEqual(timeline.state(at: 100)["x"], "100")
        XCTAssertEqual(timeline.highlights.map(\.type), ["damage", "blackBox", "docking"])
        XCTAssertTrue(ReplayTimeline(events: []).highlights.isEmpty)
        let warp = ReplayTimeline(events: [event(1, "snapshot", 0, ["x": "0", "zone": "ocean"]), event(2, "snapshot", 10, ["x": "200", "zone": "bossCave"])])
        XCTAssertEqual(warp.state(at: 5)["x"], "0")
    }
    func testFlowFilteringAndReaderCategories() async throws {
        let file = path()
        let logger = ExpeditionLogger(path: file)
        for to in ["Game", "Game", "Pause"] {
            await logger.log(expeditionId: "flow", type: "navigation", payload: ["fromScreen": "Game", "toScreen": to, "reason": "test"])
        }
        await logger.error(expeditionId: "flow", message: "test error")
        await logger.flush()
        let reader = LogReader(path: file)
        let edges = try await reader.transitions(expeditionId: "flow")
        XCTAssertEqual(edges.count, 1); XCTAssertEqual(edges.first?.to, "Pause")
        let errors = try await reader.events(expeditionId: "flow", category: "Errors")
        XCTAssertEqual(errors.count, 1)
        let absent = try await reader.transitions(expeditionId: "other")
        XCTAssertTrue(absent.isEmpty)
    }
    func testRetentionKeepsActiveAndNewest() throws {
        let store = try LogStore(path: path())
        for index in 0..<60 {
            try store.batch([.init(expeditionId: "\(index)", sequenceNumber: 1, timestamp: Date(timeIntervalSince1970: Double(index)), schemaVersion: 1, category: "Gameplay", type: "end", severity: "info", payload: ["result": "completed"])])
        }
        try store.batch([event(1, "start")]); try store.prune()
        XCTAssertEqual(try store.rows("SELECT count(*) FROM expeditions")[0][0], "50")
        XCTAssertEqual(try store.rows("SELECT result FROM expeditions WHERE id='test'")[0][0], "active")
    }

    func testFailedTransactionRollsBack() throws {
        let store = try LogStore(path: path())
        try store.execute("CREATE TRIGGER fail_event BEFORE INSERT ON events WHEN NEW.sequence=2 BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        XCTAssertThrowsError(try store.batch([event(1), event(2)]))
        XCTAssertEqual(try store.rows("SELECT count(*) FROM events")[0][0], "0")
        try store.execute("DROP TRIGGER fail_event")
        try store.batch([event(1), event(2)])
        XCTAssertEqual(try store.rows("SELECT count(*) FROM events")[0][0], "2")
    }

    func testRetryRetainsProtectedEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocked".utf8).write(to: folder)
        let file = folder.appendingPathComponent("log.sqlite").path
        let logger = ExpeditionLogger(path: file)
        for type in ["start", "navigation", "damage", "blackBox", "docking", "error", "end"] {
            await logger.log(expeditionId: "retry", type: type)
        }
        let failure = await logger.lastError
        XCTAssertNotNil(failure)
        try FileManager.default.removeItem(at: folder)
        await logger.flush()
        let events = try await LogReader(path: file).events(expeditionId: "retry")
        XCTAssertEqual(events.map(\.type), ["start", "navigation", "damage", "blackBox", "docking", "error", "end"])
        await logger.flush()
        let again = try await LogReader(path: file).events(expeditionId: "retry")
        XCTAssertEqual(again.count, 7)
    }

    @MainActor
    func testGameLoopLoggingBudget() async {
        let engine = GameEngine()
        engine.startGame()
        let start = Date()
        for _ in 0..<7200 { engine.step(deltaTime: 1.0 / 60.0) }
        let seconds = Date().timeIntervalSince(start)
        print("MainActor game simulation with logging: 7200 steps in \(seconds)s (120 simulated seconds)")
        XCTAssertLessThan(seconds, 12, "Simulation should have substantial headroom over real time")
        engine.returnToMenu()
        await engine.flushJournal()
    }
}
