import Foundation
import SQLite3

struct BoatSnapshot: Codable, Sendable {
    let x: Double
    let y: Double
    let energy: Double
    let hull: Int
    let cargo: Int
    let blackBox: Bool
    let shield: Bool
    let zone: String
    let state: String
    let speed: Double
}

struct JournalEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let diveID: UUID
    let date: Date
    let elapsed: Double
    let kind: String
    let severity: String
    let message: String
    let boat: BoatSnapshot
}

struct DiveReceipt: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let outcome: String
    let boosts: Int
    let reefs: Int
    let blackBoxes: Int
}

protocol ExpeditionLogging: Sendable {
    func record(_ entry: JournalEntry)
    func flush()
}

/// All SQLite work, encoding, batching and reads belong to this serial utility queue.
/// The caller only enqueues an immutable snapshot; it never waits for disk I/O.
final class ExpeditionJournal: ExpeditionLogging, @unchecked Sendable {
    static let shared = ExpeditionJournal(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("UnderwaterBureau/journal.sqlite"))

    private let url: URL
    private let queue = DispatchQueue(label: "UnderwaterBureau.database", qos: .utility)
    private var database: OpaquePointer?
    private var pending: [JournalEntry] = []
    private var scheduled = false
    private var storageError: String?
    private var dropped = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close(database) } }

    func record(_ entry: JournalEntry) {
        queue.async { [self] in
            // Bound memory even if the device runs out of space. Surface loss to readers.
            guard pending.count < 2048 else { dropped += 1; return }
            pending.append(entry)
            if pending.count >= 32 || entry.kind == "finish" { persist() }
            if !scheduled && !pending.isEmpty {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    scheduled = false
                    persist()
                }
            }
        }
    }

    func flush() { queue.async { [self] in persist() } }

    func receipts(offset: Int = 0, diveID: UUID? = nil) async throws -> [DiveReceipt] {
        try await read { [self] in
            let sql = """
                SELECT dive, MIN(wall), COALESCE(MAX(CASE WHEN kind='finish' THEN message END),
                'Дело не закрыто: погружение идёт или было прервано'),
                SUM(kind='boost'), SUM(kind='reef.damage'), SUM(kind='pickup.blackBox')
                FROM events \(diveID.map { "WHERE dive='\($0.uuidString)'" } ?? "") GROUP BY dive ORDER BY MIN(wall) DESC, dive LIMIT 50 OFFSET \(max(0, offset))
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var result: [DiveReceipt] = []
            while try next(statement) {
                guard let id = UUID(uuidString: string(statement, 0)) else { throw JournalError("Некорректный номер дела") }
                result.append(DiveReceipt(id: id, date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    outcome: string(statement, 2), boosts: Int(sqlite3_column_int(statement, 3)),
                    reefs: Int(sqlite3_column_int(statement, 4)), blackBoxes: Int(sqlite3_column_int(statement, 5))))
            }
            return result
        }
    }

    func entries(diveID: UUID, offset: Int = 0) async throws -> [JournalEntry] {
        try await read { [self] in
            let statement = try prepare("SELECT payload FROM events WHERE dive=? ORDER BY sequence LIMIT 200 OFFSET \(max(0, offset))")
            defer { sqlite3_finalize(statement) }
            try bind(diveID.uuidString, to: statement, at: 1)
            var result: [JournalEntry] = []
            while try next(statement) {
                result.append(try JSONDecoder().decode(JournalEntry.self, from: Data(string(statement, 0).utf8)))
            }
            return result
        }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try open()
                    persist()
                    if let storageError { throw JournalError(storageError) }
                    if dropped > 0 { throw JournalError("Журнал переполнен: потеряно событий \(dropped). Освободите место на устройстве.") }
                    continuation.resume(returning: try body())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Не удалось открыть базу"
            if let handle { sqlite3_close(handle) }
            throw JournalError(message)
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS events (
                    sequence INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, dive TEXT NOT NULL,
                    wall REAL NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL, payload TEXT NOT NULL)
                """)
            try execute("CREATE INDEX IF NOT EXISTS events_dive ON events(dive, sequence)")
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    private func persist() {
        guard !pending.isEmpty else { return }
        do {
            try open()
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare("INSERT OR IGNORE INTO events(id,dive,wall,kind,message,payload) VALUES(?,?,?,?,?,?)")
                defer { sqlite3_finalize(statement) }
                for entry in pending {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(entry.id.uuidString, to: statement, at: 1)
                    try bind(entry.diveID.uuidString, to: statement, at: 2)
                    guard sqlite3_bind_double(statement, 3, entry.date.timeIntervalSince1970) == SQLITE_OK else { throw failure() }
                    try bind(entry.kind, to: statement, at: 4)
                    try bind(entry.message, to: statement, at: 5)
                    try bind(String(decoding: JSONEncoder().encode(entry), as: UTF8.self), to: statement, at: 6)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
                }
                try execute("COMMIT")
                pending.removeAll(keepingCapacity: true)
                storageError = nil
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        } catch { storageError = "Чек не сохранён: \(error.localizedDescription). Запись будет повторена." }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }
    private func next(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }
    private func failure() -> JournalError { JournalError(String(cString: sqlite3_errmsg(database))) }
}

struct JournalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
