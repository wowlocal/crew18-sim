import Foundation
import SwiftData
import Combine
import OSLog
import UIKit

enum BlackBoxLevel: String, Codable, CaseIterable, Sendable { case debug, info, warning, error }
enum BlackBoxCategory: String, Codable, CaseIterable, Sendable { case state, control, flow, event, hazard, resource, captain, system }
struct BlackBoxEntry: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    let runID: UUID
    var seq: Int
    let t: TimeInterval
    let wallTime: Date
    var schemaVersion = 1
    let level: BlackBoxLevel
    let category: BlackBoxCategory
    let message: String
    let attrs: [String: String]
    var expendable: Bool { level == .debug || message == "snapshot" }
}
@Model final class BlackBoxRow {
    @Attribute(.unique) var id: UUID
    var runID: UUID
    var seq: Int
    var wallTime: Date
    var payload: Data
    init(_ entry: BlackBoxEntry) throws {
        id = entry.id; runID = entry.runID; seq = entry.seq; wallTime = entry.wallTime
        payload = try JSONEncoder().encode(entry)
    }
}
@ModelActor actor BlackBoxStore {
    func write(_ entries: [BlackBoxEntry]) throws {
        do {
            for entry in entries { modelContext.insert(try BlackBoxRow(entry)) }
            if entries.contains(where: { $0.message == "run.start" || $0.message == "run.end" }) {
                let retained = try retainedIDs()
                let rows = try modelContext.fetch(FetchDescriptor<BlackBoxRow>())
                for row in rows where !retained.contains(row.runID) { modelContext.delete(row) }
            }
            try modelContext.save()
        } catch { modelContext.rollback(); throw error }
    }
    func page(runID: UUID?, after: Int, limit: Int) throws -> [BlackBoxEntry] {
        let predicate: Predicate<BlackBoxRow>
        if let runID { predicate = #Predicate { $0.runID == runID && $0.seq > after } }
        else { predicate = #Predicate { $0.seq > after } }
        var request = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\BlackBoxRow.seq)])
        request.fetchLimit = min(max(limit, 1), 512)
        return try modelContext.fetch(request).map { try JSONDecoder().decode(BlackBoxEntry.self, from: $0.payload) }
    }
    func runs() throws -> [UUID] {
        let rows = try modelContext.fetch(FetchDescriptor<BlackBoxRow>(sortBy: [SortDescriptor(\BlackBoxRow.wallTime, order: .reverse)]))
        var seen = Set<UUID>()
        return try rows.compactMap { row in
            let entry = try JSONDecoder().decode(BlackBoxEntry.self, from: row.payload)
            return entry.message == "run.start" && seen.insert(row.runID).inserted ? row.runID : nil
        }
    }
    private func retainedIDs() throws -> Set<UUID> {
        var retained = Set(try runs().prefix(10))
        let rows = try modelContext.fetch(FetchDescriptor<BlackBoxRow>())
        for row in rows where retained.contains(row.runID) {
            let entry = try JSONDecoder().decode(BlackBoxEntry.self, from: row.payload)
            if let session = entry.attrs["sessionID"].flatMap(UUID.init(uuidString:)) { retained.insert(session) }
        }
        return retained
    }
    func recoverAndPrune() throws -> Int {
        let ids = try runs()
        let rows = try modelContext.fetch(FetchDescriptor<BlackBoxRow>())
        var sequence = rows.map(\.seq).max() ?? 0
        for id in ids.prefix(10) {
            let entries = try rows.filter { $0.runID == id }.map { try JSONDecoder().decode(BlackBoxEntry.self, from: $0.payload) }
            if entries.contains(where: { $0.message == "run.start" }) && !entries.contains(where: { $0.message == "run.end" }) {
                sequence += 1
                let entry = BlackBoxEntry(runID: id, seq: sequence, t: entries.map(\.t).max() ?? 0, wallTime: Date(), level: .warning, category: .system, message: "run.end", attrs: ["outcome": "interrupted"])
                modelContext.insert(try BlackBoxRow(entry))
            }
        }
        let retained = try retainedIDs()
        for row in rows where !retained.contains(row.runID) { modelContext.delete(row) }
        try modelContext.save()
        return sequence
    }
}
struct BlackBoxReader: Sendable {
    let store: BlackBoxStore
    func runs() async throws -> [UUID] { try await store.runs() }
    func page(runID: UUID? = nil, after: Int = 0, limit: Int = 100) async throws -> [BlackBoxEntry] {
        try await store.page(runID: runID, after: after, limit: limit)
    }
    func all(runID: UUID? = nil) async throws -> [BlackBoxEntry] {
        var result: [BlackBoxEntry] = [], cursor = 0
        while true {
            let batch = try await page(runID: runID, after: cursor, limit: 512)
            guard let last = batch.last else { return result }
            result += batch; cursor = last.seq
        }
    }
}
actor BlackBox {
    static let shared = BlackBox()
    private let output = Logger(subsystem: "io.podlodka.dive", category: "BlackBox")
    private var store: BlackBoxStore?
    private var buffer: [BlackBoxEntry] = []
    private var sequence = 0
    private var timer: Task<Void, Never>?
    private var writing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var recovered = false
    private var recoveryTask: Task<Int, Error>?
    private(set) var storageError: String?
    private let storeFactory: @Sendable () throws -> BlackBoxStore
    private let now: @Sendable () -> Date
    private let sleep: @Sendable () async throws -> Void
    init(store: BlackBoxStore? = nil, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
         storeFactory: @escaping @Sendable () throws -> BlackBoxStore = {
             BlackBoxStore(modelContainer: try ModelContainer(for: BlackBoxRow.self))
         }) {
        self.store = store; self.now = now; self.sleep = sleep; self.storeFactory = storeFactory
    }
    func reader() async -> BlackBoxReader? {
        await recover()
        return recovered ? store.map { BlackBoxReader(store: $0) } : nil
    }
    private func prepare() {
        if store == nil {
            do { store = try storeFactory() }
            catch {
                storageError = error.localizedDescription
                output.error("Database unavailable: \(error.localizedDescription)")
            }
        }
        guard timer == nil else { return }
        let sleep = self.sleep
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep() } catch { return }
                guard self != nil else { return }
                await self?.flush()
            }
        }
    }
    func recover() async {
        guard !recovered else { return }
        prepare()
        guard let store else { return }
        if recoveryTask == nil {
            recoveryTask = Task { try await store.recoverAndPrune() }
        }
        do {
            let restored = try await recoveryTask?.value ?? 0
            guard !recovered else { return }
            // Events buffered before the disk became available follow the persisted sequence.
            for index in buffer.indices { buffer[index].seq += restored }
            sequence += restored
            recovered = true
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            recoveryTask = nil
            output.error("Recovery failed: \(error.localizedDescription)")
        }
    }
    func log(_ level: BlackBoxLevel = .info, _ category: BlackBoxCategory, _ message: String,
             attrs: [String: String] = [:], runID: UUID, t: TimeInterval) async {
        await recover(); sequence += 1
        if level == .error { output.error("\(message, privacy: .public) \(attrs.description)") }
        if buffer.count >= 512 {
            if let index = buffer.firstIndex(where: \.expendable) { buffer.remove(at: index) }
            else if level == .debug || message == "snapshot" { return }
            // Critical events are retained even when storage is unavailable. The cap is soft for them.
        }
        buffer.append(BlackBoxEntry(runID: runID, seq: sequence, t: t, wallTime: now(), level: level, category: category, message: message, attrs: attrs))
        if buffer.count >= 64 { await flush() }
    }
    func flush() async {
        await recover()
        guard recovered else { return }
        if writing {
            await withCheckedContinuation { waiters.append($0) }
            await flush(); return
        }
        guard let store, !buffer.isEmpty else { return }
        writing = true
        let batch = buffer
        do {
            try await store.write(batch)
            let ids = Set(batch.map(\.id)); buffer.removeAll { ids.contains($0.id) }
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            output.error("Flush failed: \(error.localizedDescription)")
        }
        writing = false
        let pending = waiters; waiters = []; pending.forEach { $0.resume() }
    }
}

/// Serial task chain preserves synchronous Combine delivery order, without disk work in simulation.
@MainActor final class BlackBoxRecorder: ObservableObject {
    private let logger: BlackBox
    private var subscription: AnyCancellable?
    private var tail: Task<Void, Never>?
    private var runID = UUID()
    private var started = ProcessInfo.processInfo.systemUptime
    private var active = false
    private var ticks = 0
    private weak var engine: GameEngine?
    private var screen = "launch"
    init(engine: GameEngine, logger: BlackBox = .shared) {
        self.logger = logger
        self.engine = engine
        tail = Task { await logger.recover() }
        record(.system, "app.launch")
        if let error = engine.garageLoadError { record(.system, "garage.load.failed", level: .error, attrs: ["reason": error]) }
        subscription = engine.events.sink { [weak self, weak engine] event in
            guard let self, let engine else { return }
            switch event {
            case .runStarted(let id):
                let sessionID = runID
                runID = id; active = true; ticks = 0
                record(.state, "run.start", attrs: ["sessionID": sessionID.uuidString, "style": engine.selectedStyle.rawValue,
                    "night": String(UserDefaults.standard.bool(forKey: "podlodkaDive.nightExpedition")), "best": String(engine.bestScore)].merging(engine.missionMetadata) { _, new in new })
                snapshot(engine.situationSummary, boundary: true)
            case .runEnded(let outcome):
                guard active else { return }
                snapshot(engine.situationSummary, boundary: true)
                record(.state, "run.end", attrs: ["outcome": outcome, "score": String(engine.score), "best": String(engine.bestScore), "reason": outcome == ExpeditionOutcome.gameOver.rawValue ? String(describing: engine.failureReason) : outcome])
                active = false; flush()
                runID = UUID(); started = ProcessInfo.processInfo.systemUptime
            case .stateChanged(let state):
                record(.state, String(describing: state)); flow(String(describing: state))
            case .situation(let summary): ticks += 1; if ticks % 4 == 0 { snapshot(summary) }
            case .danger(let text): record(.hazard, text, level: .warning); snapshot(engine.situationSummary, boundary: true)
            case .speak(let text):
                record(.event, text)
            case .energyLow: record(.resource, "energyLow", level: .warning)
            case .objectiveChanged(let value): record(.event, "blackBox", attrs: ["collected": String(value)])
            case .success(let score): record(.event, "success", attrs: ["score": String(score)])
            case .record(let score): record(.event, "record", attrs: ["score": String(score)])
            case .diagnostic(let level, let category, let message, let attrs): record(category, message, level: level, attrs: attrs)
            }
        }
    }
    func timestamp() -> (UUID, Double) { (runID, active ? (engine?.runElapsed ?? 0) : ProcessInfo.processInfo.systemUptime - started) }
    func record(_ category: BlackBoxCategory, _ message: String, level: BlackBoxLevel = .info, attrs: [String: String] = [:], timestamp: (UUID, Double)? = nil) {
        let logger = self.logger
        let captured = timestamp ?? self.timestamp()
        let previous = tail, id = captured.0, t = captured.1
        tail = Task { await previous?.value; await logger.log(level, category, message, attrs: attrs, runID: id, t: t) }
    }
    func flow(_ next: String) { guard next != screen else { return }; record(.flow, "screen", attrs: ["from": screen, "to": next]); screen = next }
    func flush() { let logger = self.logger; let previous = tail; tail = Task { await previous?.value; await logger.flush() } }
    func background() {
        let token = UIApplication.shared.beginBackgroundTask(withName: "BlackBox flush")
        record(.system, "app.background")
        Task { await drain(); if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
    }
    func drain() async { await tail?.value; await logger.flush() }
    private func snapshot(_ s: SituationSummary, boundary: Bool = false) {
        record(.state, boundary ? "snapshot.boundary" : "snapshot", attrs: ["zone": s.zone, "x": String(Double(s.position.x)), "y": String(Double(s.position.y)), "energy": String(Double(s.energy)), "hull": String(s.hull), "speed": String(s.speed), "target": s.targetName ?? "Чёрный ящик"].merging(engine?.missionMetadata ?? [:]) { _, new in new })
    }
}
