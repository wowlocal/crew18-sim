import Foundation
import SQLite3

struct ExpeditionEvent: Codable, Identifiable, Sendable {
    var id: String { "\(expeditionId):\(sequenceNumber)" }
    let expeditionId: String
    let sequenceNumber: Int
    let timestamp: Date
    let schemaVersion: Int
    let category: String
    let type: String
    let severity: String
    let payload: [String: String]
    var time: Double { Double(payload["time"] ?? "0") ?? 0 }
}

struct ExpeditionSummary: Identifiable, Sendable {
    let id: String
    let date: Date
    let duration: Double
    let result: String
    let cargo: String
    let reason: String
}

/// Confined to its owning actor. No SQLite work is performed on MainActor.
final class LogStore {
    private var db: OpaquePointer?
    static var defaultPath: String {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Expedition", isDirectory: true)
        return folder.appendingPathComponent("journal.sqlite").path
    }
    init(path: String, recover: Bool = false) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 1000)
        try execute("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_size_limit=1048576; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS expeditions(id TEXT PRIMARY KEY, date REAL, duration REAL DEFAULT 0, result TEXT DEFAULT 'active', cargo TEXT DEFAULT '0', reason TEXT DEFAULT ''); CREATE TABLE IF NOT EXISTS events(expedition TEXT REFERENCES expeditions(id) ON DELETE CASCADE, sequence INTEGER, category TEXT, type TEXT, json TEXT, PRIMARY KEY(expedition,sequence)); CREATE INDEX IF NOT EXISTS event_type ON events(type,expedition,sequence);")
        if recover { try execute("UPDATE expeditions SET result='interrupted', reason='Application interrupted' WHERE result='active'") }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "ExpeditionSQLite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(result, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return result
    }
    private func write(_ sql: String, _ values: [String]) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    func batch(_ events: [ExpeditionEvent]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for event in events {
                try write("INSERT OR IGNORE INTO expeditions(id,date) VALUES(?,?)", [event.expeditionId, String(event.timestamp.timeIntervalSince1970)])
                let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
                try write("INSERT OR IGNORE INTO events VALUES(?,?,?,?,?)", [event.expeditionId, String(event.sequenceNumber), event.category, event.type, json])
                try write("UPDATE expeditions SET duration=MAX(duration,?) WHERE id=?", [String(event.time), event.expeditionId])
                if let cargo = event.payload["cargo"] {
                    try write("UPDATE expeditions SET cargo=? WHERE id=?", [cargo, event.expeditionId])
                }
                if event.type == "end" {
                    try write("UPDATE expeditions SET result=?, reason=? WHERE id=?", [event.payload["result"] ?? "ended", event.payload["reason"] ?? "", event.expeditionId])
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    /// Keep at most 50 finished runs and 32 MB of event payloads. Active runs are protected.
    func prune() throws {
        try execute("DELETE FROM expeditions WHERE result!='active' AND id NOT IN (SELECT id FROM expeditions ORDER BY date DESC LIMIT 50)")
        while let size = try rows("SELECT COALESCE(SUM(length(json)),0) FROM events").first?.first,
              (Int(size) ?? 0) > 32 * 1024 * 1024 {
            let old = try rows("SELECT id FROM expeditions WHERE result!='active' ORDER BY date LIMIT 1")
            guard let id = old.first?.first else { break }
            try write("DELETE FROM expeditions WHERE id=?", [id])
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(256)")
    }
}

actor ExpeditionLogger {
    static let shared = ExpeditionLogger()
    private let path: String
    private var store: LogStore?
    private var pending: [ExpeditionEvent] = []
    private var sequences: [String: Int] = [:]
    private var timer: Task<Void, Never>?
    private(set) var lastError: String?
    private(set) var droppedSnapshots = 0
    private(set) var batchCount = 0
    init(path: String = LogStore.defaultPath) { self.path = path }
    func log(expeditionId: String, type: String, category: String = "Gameplay", severity: String = "info", payload: [String: String] = [:]) {
        if type == "snapshot", pending.count >= 512 { droppedSnapshots += 1; return }
        let sequence = (sequences[expeditionId] ?? 0) + 1
        sequences[expeditionId] = sequence
        pending.append(.init(expeditionId: expeditionId, sequenceNumber: sequence, timestamp: Date(), schemaVersion: 1, category: category, type: type, severity: severity, payload: payload))
        if pending.count >= 64 || type == "end" { flush() }
        if timer == nil {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.timedFlush()
            }
        }
    }
    func state(expeditionId: String, payload: [String: String]) { log(expeditionId: expeditionId, type: "snapshot", category: "State", payload: payload) }
    func error(expeditionId: String, message: String) { log(expeditionId: expeditionId, type: "error", category: "Errors", severity: "error", payload: ["message": message]) }
    private func timedFlush() {
        timer = nil
        flush()
        if !pending.isEmpty {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.timedFlush()
            }
        }
    }
    func flush() {
        do {
            if store == nil { store = try LogStore(path: path, recover: true) }
            guard !pending.isEmpty else { return }
            try store?.batch(pending)
            pending.removeAll(keepingCapacity: true)
            batchCount += 1
            lastError = nil
            try store?.prune()
        } catch { lastError = error.localizedDescription }
    }
}

actor LogReader {
    private let path: String
    private var store: LogStore?
    init(path: String = LogStore.defaultPath) { self.path = path }
    private func database() throws -> LogStore {
        if let store { return store }
        let opened = try LogStore(path: path); store = opened; return opened
    }
    func expeditions(limit: Int = 30, offset: Int = 0) throws -> [ExpeditionSummary] {
        try database().rows("SELECT id,date,duration,result,cargo,reason FROM expeditions ORDER BY date DESC LIMIT ? OFFSET ?", [String(max(1, min(limit, 500))), String(max(0, offset))]).map {
            ExpeditionSummary(id: $0[0], date: Date(timeIntervalSince1970: Double($0[1]) ?? 0), duration: Double($0[2]) ?? 0, result: $0[3], cargo: $0[4], reason: $0[5])
        }
    }
    func events(expeditionId: String, after: Int = 0, category: String? = nil, limit: Int = 200) throws -> [ExpeditionEvent] {
        let filter = category == nil ? "" : " AND category=?"
        var args = [expeditionId, String(after)]
        if let category { args.append(category) }
        args.append(String(max(1, min(limit, 1000))))
        return try database().rows("SELECT json FROM events WHERE expedition=? AND sequence>?\(filter) ORDER BY sequence LIMIT ?", args).map { try JSONDecoder().decode(ExpeditionEvent.self, from: Data($0[0].utf8)) }
    }
    func transitions(expeditionId: String? = nil) throws -> [FlowEdge] {
        let rows = try database().rows("SELECT json FROM events WHERE type='navigation'" + (expeditionId == nil ? "" : " AND expedition=?"), expeditionId.map { [$0] } ?? [])
        return FlowEdge.aggregate(try rows.map { try JSONDecoder().decode(ExpeditionEvent.self, from: Data($0[0].utf8)) })
    }
}

struct FlowEdge: Identifiable, Sendable {
    let from: String
    let to: String
    var count: Int
    var id: String { from + "→" + to }
    static func aggregate(_ events: [ExpeditionEvent]) -> [FlowEdge] {
        var edges: [String: FlowEdge] = [:]
        for event in events where event.type == "navigation" {
            guard let from = event.payload["fromScreen"], let to = event.payload["toScreen"], from != to else { continue }
            let edge = FlowEdge(from: from, to: to, count: 0)
            edges[edge.id, default: edge].count += 1
        }
        return edges.values.sorted { $0.id < $1.id }
    }
}

struct ReplayTimeline: Sendable {
    let events: [ExpeditionEvent]
    let duration: Double
    let snapshots: [ExpeditionEvent]
    let highlights: [ExpeditionEvent]
    init(events: [ExpeditionEvent]) {
        self.events = events
        duration = events.map(\.time).max() ?? 0
        highlights = Self.selectHighlights(events, duration: duration)
        snapshots = events.filter { $0.payload["x"] != nil }.sorted { $0.time == $1.time ? $0.sequenceNumber < $1.sequenceNumber : $0.time < $1.time }
    }
    func state(at time: Double) -> [String: String] {
        let frames = snapshots
        guard let first = frames.first else { return [:] }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let previous = low > 0 ? frames[low - 1] : first
        var result = previous.payload
        if low < frames.count, frames[low].time > previous.time,
           frames[low].payload["zone"] == previous.payload["zone"] {
            let next = frames[low]
            let fraction = max(0, min(1, (time - previous.time) / (next.time - previous.time)))
            for key in ["x", "y", "vx", "vy"] {
                if let a = Double(previous.payload[key] ?? ""), let b = Double(next.payload[key] ?? "") { result[key] = String(a + (b - a) * fraction) }
            }
        }
        return result
    }
    private static func selectHighlights(_ events: [ExpeditionEvent], duration: Double) -> [ExpeditionEvent] {
        let priorities = ["blackBox": 3, "docking": 3, "damage": 2, "mine": 2, "pickup": 1, "sonar": 1, "boost": 1]
        var selected: [ExpeditionEvent] = []
        for event in events.sorted(by: { (priorities[$0.type] ?? 0) == (priorities[$1.type] ?? 0) ? $0.sequenceNumber < $1.sequenceNumber : (priorities[$0.type] ?? 0) > (priorities[$1.type] ?? 0) }) where priorities[event.type] != nil {
            if selected.allSatisfy({ abs($0.time - event.time) >= max(5, duration * 0.08) }) { selected.append(event) }
            if selected.count == 3 { break }
        }
        return selected.sorted { $0.time < $1.time }
    }
}
