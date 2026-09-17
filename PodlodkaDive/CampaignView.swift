import SwiftUI

struct CampaignView: View {
  @ObservedObject var engine: GameEngine
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Button("Закрыть") { dismiss() }
            .frame(minHeight: 44).accessibilityIdentifier("closeCampaign")
          Text(
            "Три района океана, три разные задачи. Заверши рейс и вернись на базу, чтобы открыть следующий."
          )
          ForEach(CampaignMission.allCases) { mission in
            let unlocked = engine.campaignProgress.isUnlocked(mission)
            let complete = engine.campaignProgress.completed.contains(mission)
            VStack(alignment: .leading, spacing: 12) {
              Text("\(mission.number). \(mission.title)").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
              Text(mission.briefing)
              Text(mission.hint)
              Text(
                complete
                  ? "Пройдена · рекорд задания: \(engine.campaignProgress.bestScores[mission.rawValue] ?? 0)"
                  : (unlocked ? "Доступна" : "Сначала заверши предыдущую экспедицию")
              )
              .fontWeight(.semibold)
              .accessibilityIdentifier("missionStatus-\(mission.rawValue)")
              if unlocked {
                Button {
                  if engine.selectMission(mission) { dismiss() }
                } label: {
                  Label(
                    engine.mission == mission ? "Выбрана · к подготовке" : "Выбрать экспедицию",
                    systemImage: engine.mission == mission
                      ? "checkmark.circle" : "arrow.right.circle"
                  )
                  .frame(maxWidth: .infinity, minHeight: 48)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent).tint(OceanPalette.teal).foregroundStyle(
                  OceanPalette.ink
                )
                .accessibilityIdentifier("selectMission-\(mission.rawValue)")
              } else {
                Label("Пока закрыта", systemImage: "lock.fill")
              }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color(red: 0.035, green: 0.15, blue: 0.20), in: RoundedRectangle(cornerRadius: 20))
          }
          if engine.campaignProgress.completed.count == CampaignMission.allCases.count {
            Text("Кампания пройдена. Все экспедиции доступны для повторных погружений.")
              .font(.title2).accessibilityIdentifier("campaignComplete")
          }
        }
        .font(.body).foregroundStyle(.white).padding(20)
      }
      .background(OceanPalette.ink).navigationTitle("Экспедиции")
    }
    .preferredColorScheme(.dark)
  }
}
