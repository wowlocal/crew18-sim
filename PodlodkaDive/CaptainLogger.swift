import Foundation
import SwiftUI

/// Queue-confined storage: encoding and disk access never run on the game/UI thread.
final class CaptainLogger: @unchecked Sendable {
    enum Sobriety: String, Codable, CaseIterable, Sendable {
        case sober, tipsy, drunken
        var title: String {
            switch self {
            case .sober: "Трезв как стекло"
            case .tipsy: "Слегка навеселе"
            case .drunken: "Совсем пьян"
            }
        }
    }

    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let date: Date
        let expedition: UUID
        let event: String
        let sobriety: Sobriety
        let message: String
        let details: [String: String]
    }

    static let shared = CaptainLogger(url: URL.applicationSupportDirectory
        .appendingPathComponent("CaptainLogger/watch-journal.json"))
    private let queue = DispatchQueue(label: "CaptainLogger.storage", qos: .utility)
    private let url: URL
    private var entries: [Entry] = []
    private var loaded = false
    private var dirty = false
    private var scheduled = false
    private var storageError: String?
    private var loadFailed = false
    private let capacity: Int

    init(url: URL, capacity: Int = 2_000) {
        self.url = url
        self.capacity = max(1, capacity)
    }

    func record(_ event: String, message: String, expedition: UUID,
                sobriety: Sobriety, details: [String: String] = [:]) {
        let prose: String
        switch sobriety {
        case .sober: prose = message
        case .tipsy: prose = "Так, записываю… \(message)"
        case .drunken:
            prose = "\(message) Эх, нелегка служба на подлодке: потолок низкий, море со всех сторон, а до дома ещё сколько вахт… Даже чай в кружке мечтает сойти на берег."
        }
        let entry = Entry(id: UUID(), date: Date(), expedition: expedition, event: event,
                          sobriety: sobriety, message: prose,
                          details: sobriety == .sober ? details : details.filter { ["hull", "energy", "reason"].contains($0.key) })
        queue.async {
            self.load()
            self.entries.append(entry)
            self.entries = Array(self.entries.suffix(self.capacity))
            self.dirty = true
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.scheduled = false
                self.persist()
            }
        }
    }

    /// Flushes queued events before returning newest-first records. Errors remain visible to readers.
    func read() async -> (entries: [Entry], error: String?) {
        await withCheckedContinuation { continuation in
            queue.async {
                self.load()
                self.persist()
                continuation.resume(returning: (self.entries.reversed(), self.storageError))
            }
        }
    }

    func flush() {
        queue.async { self.load(); self.persist() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            entries = Array(try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)).suffix(capacity))
        } catch {
            loadFailed = true // Never overwrite an unreadable historical journal.
            storageError = "Не удалось прочитать журнал: \(error.localizedDescription)"
        }
    }

    private func persist() {
        guard dirty, !loadFailed else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            dirty = false
            storageError = nil
        } catch {
            storageError = "Не удалось сохранить журнал: \(error.localizedDescription)"
        }
    }
}

struct CaptainJournalView: View {
    let logger: CaptainLogger
    @AppStorage("podlodkaDive.captainSobriety") private var sobriety = CaptainLogger.Sobriety.sober
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CaptainLogger.Entry] = []
    @State private var storageError: String?
    @State private var query = ""
    @State private var visibleLimit = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Вахтенный журнал").font(.title).accessibilityAddTraits(.isHeader)
                Button("Готово") { dismiss() }
                Text("Степень трезвости").font(.body)
                ForEach(CaptainLogger.Sobriety.allCases, id: \.self) { value in
                    Button {
                        sobriety = value
                    } label: {
                        Label(value.title, systemImage: sobriety == value ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityAddTraits(sobriety == value ? .isSelected : [])
                }
                Text("Трезвый капитан фиксирует все приборы. Навеселе — только корпус и заряд. Пьяный ещё и рассуждает о службе.")
                TextField("Поиск событий", text: $query).textFieldStyle(.roundedBorder)
                Button("Обновить") { Task { await reload() } }
                if let storageError { Text(storageError) }
                Text("Последние записи · до 2000").font(.body)
                if entries.isEmpty { Text("Вахтенный журнал пока пуст.") }
                ForEach(entries.filter { query.isEmpty || $0.message.localizedCaseInsensitiveContains(query) || $0.event.localizedCaseInsensitiveContains(query) }.prefix(visibleLimit)) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                        Text(entry.message)
                        Text("\(entry.sobriety.title) · \(entry.event) · рейс \(entry.expedition.uuidString.prefix(8))")
                        ForEach(entry.details.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(entry.details[key] ?? "")")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
                if visibleLimit < entries.count { Button("Ещё записи") { visibleLimit += 50 }.font(.body) }
            }
            .font(.body)
            .padding(24)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .foregroundStyle(.black)
        .background(.white)
        .tint(.black)
        .preferredColorScheme(.light)
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: query) { _, _ in visibleLimit = 50 }
    }

    private func reload() async {
        let result = await logger.read()
        entries = result.entries
        storageError = result.error
    }
}
