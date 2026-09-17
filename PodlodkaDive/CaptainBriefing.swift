import SwiftUI

struct CaptainBriefingData {
    let recent: [BlackBoxEntry]
    let quote: String?
    let days: Int
    static func message(for entry: BlackBoxEntry) -> String {
        if entry.category == .captain || entry.message.contains(where: { $0.isWhitespace }) { return entry.message }
        switch entry.message {
        case "mission.start", "run.start": return String(localized: "briefing.event.started")
        case "blackBox": return String(localized: "briefing.cargo")
        case "energyLow": return String(localized: "briefing.event.energy")
        case "success": return String(localized: "briefing.event.success")
        default:
            switch entry.category {
            case .hazard: return String(localized: "briefing.event.hazard")
            case .resource: return String(localized: "briefing.event.resource")
            default: return String(localized: "briefing.event.updated")
            }
        }
    }
    init(snapshot: ExpeditionSnapshot, entries: [BlackBoxEntry], now: Date, calendar: Calendar = .current) {
        let matching = entries.filter { $0.runID == snapshot.id && $0.wallTime <= (snapshot.savedAt ?? now) }.sorted { $0.seq < $1.seq }
        recent = Array(matching.filter { !$0.expendable && [.event, .hazard, .resource, .captain].contains($0.category) }.suffix(5))
        quote = matching.last { $0.category == .captain && $0.level != .error }?.message
        days = max(0, calendar.dateComponents([.day], from: snapshot.savedAt ?? now, to: now).day ?? 0)
    }
}

struct CaptainBriefing: View {
    @ObservedObject var engine: GameEngine
    let snapshot: ExpeditionSnapshot
    let now: Date
    let resume: () -> Void
    let restart: () -> Void
    @State private var entries: [BlackBoxEntry] = []
    @State private var confirmRestart = false
    @AccessibilityFocusState private var titleFocused: Bool
    var body: some View {
        let data = CaptainBriefingData(snapshot: snapshot, entries: entries, now: now)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("briefing.title").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    Text(String.localizedStringWithFormat(String(localized: "briefing.absence"), data.days))
                    Text(engine.objectiveText)
                    Text(snapshot.missionRun?.mission.briefing ?? CampaignMission.aster.briefing)
                    ExpeditionMap(engine: engine).frame(height: 240)
                    Text(String.localizedStringWithFormat(String(localized: "briefing.resources"), Int(snapshot.energy), snapshot.hull, snapshot.samples))
                    Text(String.localizedStringWithFormat(String(localized: "briefing.cargoValue"), engine.cargoValue))
                    if snapshot.hasBlackBox { Text("briefing.cargo") }
                    ForEach(data.recent) { Text(CaptainBriefingData.message(for: $0)) }
                    if let quote = data.quote { Text(quote).italic() }
                    Button("shortcut.continue", action: resume).buttonStyle(.borderedProminent).tint(OceanPalette.gold).foregroundStyle(.black).controlSize(.large).frame(minHeight: 44).accessibilityIdentifier("briefingResume")
                    Button("briefing.restart") { confirmRestart = true }.frame(minHeight: 44)
                }.padding()
            }
            .confirmationDialog("briefing.restartConfirmation", isPresented: $confirmRestart) {
                Button("briefing.restart", role: .destructive, action: restart)
            }
            .task {
                titleFocused = true
                if let reader = await BlackBox.shared.reader() { entries = (try? await reader.all(runID: snapshot.id)) ?? [] }
            }
        }.interactiveDismissDisabled()
    }
}
