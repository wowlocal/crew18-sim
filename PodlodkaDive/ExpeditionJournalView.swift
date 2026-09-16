import SwiftUI

struct ExpeditionJournalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [ExpeditionSummary] = []
    @State private var error: String?
    @State private var hasMore = true
    private let reader = LogReader()
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Граф всех игр") { ExpeditionFlowView(expeditionId: nil) }
                    .accessibilityIdentifier("allFlows")
                if let error { Text(error).foregroundStyle(.red) }
                if runs.isEmpty { Text("Экспедиций пока нет") }
                ForEach(runs) { run in
                    NavigationLink {
                        ExpeditionDetailView(run: run)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(run.date, style: .date)
                            Text(run.date, style: .time)
                            Text("\(run.result) · \(Int(run.duration)) с · Груз: \(run.cargo)")
                            if !run.reason.isEmpty { Text(run.reason).font(.caption) }
                        }
                    }.accessibilityIdentifier("expeditionRow")
                }
                if hasMore { Button("Ещё экспедиции") { Task { await load() } } }
            }
            .navigationTitle("Журнал экспедиций")
            .toolbar { Button("Закрыть") { dismiss() } }
            .task { await ExpeditionLogger.shared.flush(); await load() }
        }
    }
    private func load() async {
        do {
            let page = try await reader.expeditions(offset: runs.count)
            runs.append(contentsOf: page); hasMore = page.count == 30
            error = await ExpeditionLogger.shared.lastError
        } catch { self.error = error.localizedDescription }
    }
}

struct ExpeditionDetailView: View {
    let run: ExpeditionSummary
    @State private var category = "Все"
    @State private var events: [ExpeditionEvent] = []
    @State private var error: String?
    @State private var hasMore = true
    private let reader = LogReader()
    var body: some View {
        List {
            NavigationLink("Реплей") { ExpeditionReplayView(expeditionId: run.id) }.accessibilityIdentifier("replay")
            NavigationLink("Граф переходов") { ExpeditionFlowView(expeditionId: run.id) }.accessibilityIdentifier("runFlow")
            Picker("Фильтр", selection: $category) {
                ForEach(["Все", "Gameplay", "State", "Errors"], id: \.self) { Text($0) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(events) { event in
                DisclosureGroup("\(event.sequenceNumber) · \(String(format: "%.1f", event.time)) с · \(event.type)") {
                    Text("\(event.timestamp.formatted()) · v\(event.schemaVersion) · \(event.severity)")
                    ForEach(event.payload.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(event.payload[key] ?? "")").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if hasMore { Button("Ещё события") { Task { await load() } } }
        }
        .navigationTitle("События")
        .task(id: category) { events = []; hasMore = true; await load() }
    }
    private func load() async {
        let filter = category
        do {
            let page = try await reader.events(expeditionId: run.id, after: events.last?.sequenceNumber ?? 0, category: filter == "Все" ? nil : filter)
            guard !Task.isCancelled, filter == category else { return }
            events.append(contentsOf: page); hasMore = page.count == 200
        } catch { self.error = error.localizedDescription }
    }
}

struct ExpeditionReplayView: View {
    let expeditionId: String
    @State private var timeline = ReplayTimeline(events: [])
    @State private var time = 0.0
    @State private var playing = false
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading { ProgressView("Чтение реплея…") }
                if let error { Text(error).foregroundStyle(.red) }
                ReplayMap(state: timeline.state(at: time)).frame(height: 330)
                    .accessibilityLabel("Положение лодки на записи")
                Text("\(time, specifier: "%.1f") / \(timeline.duration, specifier: "%.1f") с")
                    .monospacedDigit().accessibilityIdentifier("replayTime")
                Button(playing ? "Пауза" : "Воспроизвести") {
                    if time >= timeline.duration { time = 0 }
                    playing.toggle()
                }.accessibilityIdentifier("replayPlay").disabled(timeline.duration <= 0)
                Slider(value: $time, in: 0...max(0.001, timeline.duration)) { _ in playing = false }
                    .accessibilityLabel("Время реплея").accessibilityIdentifier("replayTimeline")
                GeometryReader { geometry in
                    ForEach(timeline.highlights) { event in
                        Button { playing = false; time = event.time } label: { Image(systemName: "bookmark.fill") }
                            .accessibilityLabel("\(event.type), \(Int(event.time)) секунд")
                            .position(x: 12 + (geometry.size.width - 24) * event.time / max(1, timeline.duration), y: 12)
                    }
                }.frame(height: 30)
                ForEach(timeline.highlights) { event in
                    Button("\(event.type) · \(Int(event.time)) с") { playing = false; time = event.time }
                        .accessibilityIdentifier("replayHighlight")
                }
                let state = timeline.state(at: time)
                Text("Энергия: \(state["energy"] ?? "—") · Корпус: \(state["hull"] ?? "—")")
                Text("Груз: \(state["cargo"] ?? "—") · Цель: \(state["target"] ?? "—")")
                ForEach(timeline.events.filter { $0.type != "snapshot" && $0.time <= time && $0.time >= time - 3 }.suffix(5)) { event in
                    Text(event.type).font(.caption)
                }
            }.padding()
        }
        .navigationTitle("Реплей")
        .task {
            do {
                let reader = LogReader()
                var events: [ExpeditionEvent] = []
                while !Task.isCancelled {
                    let page = try await reader.events(expeditionId: expeditionId, after: events.last?.sequenceNumber ?? 0, limit: 1000)
                    events.append(contentsOf: page)
                    if page.count < 1000 { break }
                }
                timeline = ReplayTimeline(events: events); loading = false
            } catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id: playing) {
            guard playing else { return }
            let start = Date().timeIntervalSinceReferenceDate - time
            while !Task.isCancelled && playing {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                time = min(timeline.duration, Date().timeIntervalSinceReferenceDate - start)
                if time >= timeline.duration { playing = false }
            }
        }
        .onDisappear { playing = false }
    }
}

private struct ReplayMap: View {
    let state: [String: String]
    var body: some View {
        Canvas { context, size in
            let width = Double(state["width"] ?? "1560") ?? 1560
            let height = Double(state["height"] ?? "2600") ?? 2600
            let scale = min(size.width / width, size.height / height)
            func point(_ x: String, _ y: String) -> CGPoint { CGPoint(x: (Double(x) ?? 0) * scale, y: (Double(y) ?? 0) * scale) }
            if state["zone"] == "ocean" {
                for rock in (state["rocks"] ?? "").split(separator: ";") {
                    let vertices = rock.split(separator: ":").map { $0.split(separator: ",").map(String.init) }.filter { $0.count == 2 }
                    var path = Path()
                    for (index, vertex) in vertices.enumerated() {
                        let p = point(vertex[0], vertex[1])
                        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath(); context.fill(path, with: .color(.gray.opacity(0.5)))
                }
                for key in ["pickups", "mines"] {
                    for object in (state[key] ?? "").split(separator: ";") {
                        let parts = object.split(separator: ",").map(String.init)
                        guard parts.count >= 4, parts[1] != "spent" else { continue }
                        let p = point(parts[2], parts[3])
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(key == "mines" ? .red : .green))
                    }
                }
            }
            let target = point(state["targetX"] ?? "0", state["targetY"] ?? "0")
            context.stroke(Path(ellipseIn: CGRect(x: target.x - 6, y: target.y - 6, width: 12, height: 12)), with: .color(.orange), lineWidth: 2)
            let boat = point(state["x"] ?? "0", state["y"] ?? "0")
            context.fill(Path(ellipseIn: CGRect(x: boat.x - 6, y: boat.y - 4, width: 12, height: 8)), with: .color(.cyan))
        }.background(.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ExpeditionFlowView: View {
    let expeditionId: String?
    @State private var edges: [FlowEdge] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack {
                Text(expeditionId == nil ? "Все экспедиции" : "Эта экспедиция")
                Canvas { context, size in
                    let nodes = Array(Set(edges.flatMap { [$0.from, $0.to] })).sorted()
                    func point(_ name: String) -> CGPoint {
                        let index = nodes.firstIndex(of: name) ?? 0
                        let angle = Double(index) / Double(max(1, nodes.count)) * 2 * .pi - .pi / 2
                        return CGPoint(x: size.width / 2 + cos(angle) * size.width * 0.35, y: size.height / 2 + sin(angle) * size.height * 0.35)
                    }
                    for edge in edges {
                        let a = point(edge.from), b = point(edge.to)
                        let angle = atan2(b.y - a.y, b.x - a.x)
                        let end = CGPoint(x: b.x - cos(angle) * 30, y: b.y - sin(angle) * 30)
                        var path = Path(); path.move(to: a); path.addLine(to: end)
                        path.move(to: CGPoint(x: end.x - cos(angle - 0.5) * 10, y: end.y - sin(angle - 0.5) * 10))
                        path.addLine(to: end)
                        path.addLine(to: CGPoint(x: end.x - cos(angle + 0.5) * 10, y: end.y - sin(angle + 0.5) * 10))
                        context.stroke(path, with: .color(.cyan), lineWidth: 2)
                        context.draw(Text("\(edge.count)").font(.caption).foregroundStyle(.orange), at: CGPoint(x: a.x * 0.4 + b.x * 0.6, y: a.y * 0.4 + b.y * 0.6 - 10))
                    }
                    for node in nodes {
                        context.draw(Text(node).font(.caption.bold()).foregroundStyle(.white), at: point(node))
                    }
                }.frame(height: 330).accessibilityHidden(true)
                if edges.isEmpty { Text("Переходов пока нет") }
                ForEach(edges) { edge in Text("\(edge.from) → \(edge.to): \(edge.count)") }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle("Граф переходов")
        .accessibilityIdentifier("flowGraph")
        .task {
            do { edges = try await LogReader().transitions(expeditionId: expeditionId) }
            catch { self.error = error.localizedDescription }
        }
    }
}
