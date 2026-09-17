import SwiftUI
import Speech
import AVFoundation

@MainActor protocol VoiceNoteTranscriber: AnyObject {
    func start(update: @escaping @MainActor (String) -> Void, failure: @escaping @MainActor (String) -> Void) async throws
    func stop()
}
@MainActor final class DeviceVoiceNoteTranscriber: VoiceNoteTranscriber {
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var installed = false
    func start(update: @escaping @MainActor (String) -> Void, failure: @escaping @MainActor (String) -> Void) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard status == .authorized, microphone else { throw NoteError.permission }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw NoteError.unavailable }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker]); try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        self.request = request
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { stop(); throw NoteError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        installed = true
        task = recognizer.recognitionTask(with: request) { result, error in
            if let error { Task { @MainActor in failure(error.localizedDescription) } }
            if let text = result?.bestTranscription.formattedString { Task { @MainActor in update(text) } }
        }
        do { audio.prepare(); try audio.start() } catch { stop(); throw error }
    }
    func stop() {
        audio.stop()
        if installed { audio.inputNode.removeTap(onBus: 0); installed = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    enum NoteError: LocalizedError {
        case permission, unavailable
        var errorDescription: String? { String(localized: "journal.voice.unavailable") }
    }
}
@MainActor final class CaptainNote: ObservableObject {
    @Published var recording = false
    @Published var busy = false
    @Published var text = ""
    @Published var error: String?
    private var generation = 0
    private var timestamp: (UUID, Double)?
    private let transcriber: any VoiceNoteTranscriber
    init(transcriber: any VoiceNoteTranscriber = DeviceVoiceNoteTranscriber()) { self.transcriber = transcriber }
    func toggle(recorder: BlackBoxRecorder) async {
        guard !busy else { return }
        if recording { finish(recorder: recorder); return }
        busy = true; text = ""; error = nil
        generation += 1; let attempt = generation
        timestamp = recorder.timestamp()
        do {
            try await transcriber.start(update: { [weak self] text in
                guard let self, self.generation == attempt else { return }
                self.text = text
            }, failure: { [weak self] reason in
                guard let self, self.generation == attempt else { return }
                self.error = reason; self.finish(recorder: recorder)
                recorder.record(.captain, "voice.failed", level: .error, attrs: ["reason": reason])
            })
            guard generation == attempt else { transcriber.stop(); busy = false; return }
            recording = true
        }
        catch {
            transcriber.stop()
            if generation == attempt {
                self.error = error.localizedDescription
                recorder.record(.captain, "voice.denied", level: .error, attrs: ["reason": error.localizedDescription])
            }
        }
        busy = false
    }
    func finish(recorder: BlackBoxRecorder) {
        generation += 1
        guard recording else { return }
        transcriber.stop(); recording = false
        if !text.isEmpty { recorder.record(.captain, text, timestamp: timestamp); recorder.flush() }
    }
}

struct ReplaySample: Equatable {
    let zone: String
    let t: Double
    let x: Double
    let y: Double
    let energy: Double
    let hull: Double
    let speed: Double
    init?(_ entry: BlackBoxEntry) {
        guard entry.message.hasPrefix("snapshot"), let x = Double(entry.attrs["x"] ?? ""), let y = Double(entry.attrs["y"] ?? "") else { return nil }
        zone = entry.attrs["zone"] ?? "ocean"
        t = entry.t; self.x = x; self.y = y
        energy = Double(entry.attrs["energy"] ?? "") ?? 0
        hull = Double(entry.attrs["hull"] ?? "") ?? 0
        speed = Double(entry.attrs["speed"] ?? "") ?? 0
    }
    init(t: Double, x: Double, y: Double, energy: Double, hull: Double, speed: Double, zone: String = "ocean") {
        self.zone = zone
        self.t = t; self.x = x; self.y = y; self.energy = energy; self.hull = hull; self.speed = speed
    }
    static func interpolate(_ samples: [ReplaySample], at t: Double) -> ReplaySample? {
        guard let first = samples.first else { return nil }
        let a = samples.last(where: { $0.t <= t }) ?? first
        let b = samples.first(where: { $0.t > t }) ?? a
        let fraction = b.t > a.t && a.zone == b.zone ? max(0, min(1, (t - a.t) / (b.t - a.t))) : 0
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * fraction }
        return ReplaySample(t: t, x: mix(a.x, b.x), y: mix(a.y, b.y), energy: mix(a.energy, b.energy), hull: a.hull, speed: mix(a.speed, b.speed), zone: a.zone)
    }
}
struct BlackBoxJournal: View {
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [UUID] = []
    @State private var reader: BlackBoxReader?
    @State private var error = ""
    var body: some View {
        NavigationStack {
            List {
                Button("journal.close") { dismiss() }.font(.body).frame(minHeight: 44)
                if !error.isEmpty { Text(error) }
                NavigationLink("journal.flow") { JournalTimeline(reader: reader, runID: nil) }.accessibilityIdentifier("blackBoxFlow")
                ForEach(runs, id: \.self) { id in
                    NavigationLink(id.uuidString.prefix(8)) { JournalTimeline(reader: reader, runID: id) }.accessibilityIdentifier("journalRun")
                }
                if runs.isEmpty { Text("journal.empty") }
            }
            .font(.body)
            .navigationTitle("journal.title")
            .task {
                await BlackBox.shared.flush()
                reader = await BlackBox.shared.reader()
                if let failure = await BlackBox.shared.storageError { error = failure }
                do { runs = try await reader?.runs() ?? []; if reader == nil { error = String(localized: "journal.storage.error") } }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
struct JournalTimeline: View {
    let reader: BlackBoxReader?
    let runID: UUID?
    @State private var entries: [BlackBoxEntry] = []
    @State private var category = "all"
    @State private var time = 0.0
    @State private var playing = false
    @State private var error = ""
    @State private var exportURL: URL?
    @State private var spokenEvent: UUID?
    @State private var visibleLimit = 100
    private var samples: [ReplaySample] { entries.compactMap(ReplaySample.init).sorted { $0.t < $1.t } }
    private var duration: Double { max(entries.map(\.t).max() ?? 0, 0.001) }
    private var filtered: [BlackBoxEntry] { entries.filter { category == "all" || $0.category.rawValue == category } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !error.isEmpty { Text(error) }
                if runID != nil {
                    Section("journal.replay") {
                        ExpeditionMap(samples: samples, entries: entries, time: time).frame(height: 260)
                        if let sample = ReplaySample.interpolate(samples, at: time) {
                            Text("E \(Int(sample.energy))% · ♥ \(Int(sample.hull)) · \(Int(sample.speed)) m/s")
                        }
                        Text("\(time, specifier: "%.1f") / \(duration, specifier: "%.1f") с")
                            .accessibilityIdentifier("replayTime")
                        Slider(value: $time, in: 0...duration).accessibilityIdentifier("replaySeek").accessibilityLabel(Text("journal.seek"))
                            .accessibilityValue(Text("\(Int(time)) s"))
                        Button { playing.toggle() } label: {
                            Text(playing ? "journal.pause" : "journal.play")
                                .font(.body).frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                }
                Section("journal.flow") { FlowGraph(entries: entries).frame(minHeight: 220) }
                Picker("journal.filter", selection: $category) {
                    Text("journal.all").tag("all")
                    ForEach(BlackBoxCategory.allCases, id: \.rawValue) { Text(LocalizedStringKey("journal.category." + $0.rawValue)).tag($0.rawValue) }
                }
                if let exportURL { ShareLink(item: exportURL) { Label("journal.export", systemImage: "square.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle()) } }
                ShareLink(item: entries.map { "\(Int($0.t))s [\($0.category.rawValue)] \($0.message)" }.joined(separator: "\n")) { Text("journal.summary").frame(minHeight: 44).contentShape(Rectangle()) }
                ForEach(filtered.prefix(visibleLimit)) { entry in
                    Button { time = entry.t; playing = false; UIAccessibility.post(notification: .announcement, argument: entry.message) } label: {
                        VStack(alignment: .leading) {
                            Text("\(Int(entry.t))s · \(entry.category.rawValue)").font(.body)
                            Text(entry.category == .captain ? "“\(entry.message)”" : entry.message)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(8)
                    .background(abs(entry.t - time) < 0.5 ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                if visibleLimit < filtered.count { Button { visibleLimit += 100 } label: { Text("Ещё события").frame(minHeight: 44).contentShape(Rectangle()) } }
            }
            .font(.body).foregroundStyle(.primary).buttonStyle(.plain).padding(20)
            .onChange(of: category) { _, _ in visibleLimit = 100 }
            .onChange(of: time) { _, value in
                if let entry = filtered.last(where: { $0.t <= value }) {
                    if abs(entry.t - value) < 0.11 && entry.category != .state && spokenEvent != entry.id {
                        spokenEvent = entry.id
                        UIAccessibility.post(notification: .announcement, argument: entry.message)
                    }
                }
            }
        }
        .font(.body)
            .navigationTitle("journal.title")
        .task {
            do {
                entries = try await reader?.all(runID: runID) ?? []
                let exported = entries, exportID = runID
                exportURL = try await Task.detached(priority: .utility) {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(exported)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blackbox-\(exportID?.uuidString ?? "all").json")
                    try data.write(to: url, options: .atomic); return url
                }.value
            } catch { self.error = error.localizedDescription }
        }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                time = min(duration, time + 0.1)
                if time >= duration { playing = false; return }
            }
        }
    }
}
struct ReplayMap: View {
    let samples: [ReplaySample]
    let entries: [BlackBoxEntry]
    let time: Double
    var body: some View {
        Canvas { context, size in
            let level = OceanLevel.expedition
            let zone = ReplaySample.interpolate(samples, at: time)?.zone ?? "ocean"
            let bounds = zone == "bossCave" ? GameEngine.caveSize : level.size
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            for rock in zone == "ocean" ? level.rocks : [] {
                var path = Path(); path.addLines(rock.vertices.map { point($0.x, $0.y) }); path.closeSubpath()
                context.fill(path, with: .color(.teal.opacity(0.3)))
            }
            var path = Path()
            var previousZone = ""
            for sample in samples {
                if sample.zone == zone {
                    if previousZone == zone { path.addLine(to: point(sample.x, sample.y)) }
                    else { path.move(to: point(sample.x, sample.y)) }
                }
                previousZone = sample.zone
            }
            context.stroke(path, with: .color(.teal), lineWidth: 2)
            for entry in entries where entry.category == .captain || entry.category == .hazard || entry.message == "blackBox" {
                if let sample = ReplaySample.interpolate(samples, at: entry.t), sample.zone == zone {
                    let p = point(sample.x, sample.y)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.orange))
                    if entry.category == .captain && abs(entry.t - time) < 3 {
                        context.draw(Text("“\(entry.message.prefix(40))”").font(.body), at: CGPoint(x: p.x, y: p.y - 16))
                    }
                }
            }
            if let sample = ReplaySample.interpolate(samples, at: time) {
                let p = point(sample.x, sample.y)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
            }
        }.accessibilityLabel(Text("journal.replay"))
    }
}
struct FlowGraph: View {
    let entries: [BlackBoxEntry]
    private var edges: [String: Int] {
        entries.filter { $0.category == .flow }.reduce(into: [:]) { result, entry in
            result["\(entry.attrs["from"] ?? "?") → \(entry.attrs["to"] ?? "?")", default: 0] += 1
        }
    }
    var body: some View {
        VStack(alignment: .leading) {
            FlowGraphRows(edges: edges.keys.sorted().compactMap { key in
                let parts = key.components(separatedBy: " → ")
                guard parts.count == 2 else { return nil }
                return FlowEdge(from: parts[0], to: parts[1], count: edges[key] ?? 0)
            })
        }
    }
}

/// Live and historical presentations of the expedition map; replay never mutates an engine.
struct ExpeditionMap: View {
    var engine: GameEngine? = nil
    var samples: [ReplaySample] = []
    var entries: [BlackBoxEntry] = []
    var time: Double = 0
    var body: some View {
        if let engine { LiveExpeditionMap(engine: engine) }
        else { ReplayMap(samples: samples, entries: entries, time: time) }
    }
}
