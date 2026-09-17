import CoreGraphics
import Foundation

enum CampaignMission: String, Codable, CaseIterable, Identifiable {
  case aster, currentStation, silentSignal

  var id: String { rawValue }
  var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
  var title: String {
    switch self {
    case .aster: "Затонувший «Астер»"
    case .currentStation: "Подводный экспресс"
    case .silentSignal: "Сигнал из темноты"
    }
  }
  var briefing: String {
    switch self {
    case .aster:
      "Найди чёрный ящик на «Астере» и доставь его на базу. Выбирай безопасный обход или путь через мины."
    case .currentStation:
      "Оборудование уже на борту. Доставь его на станцию «Течение», затем вернись домой."
    case .silentSignal:
      "Найди аппарат «Луч» среди трёх сигналов. Проверь их сонаром поблизости и доставь аппарат на базу."
    }
  }
  var hint: String {
    switch self {
    case .aster: "Сонар бесплатный. Карта ставит игру на паузу. Сохрани заряд на возвращение."
    case .currentStation:
      "Восточный поток несёт к станции, западный — к базе. Для разгрузки остановись в круге станции."
    case .silentSignal:
      "Подойди к сигналу ближе 35 м и включи сонар. Два сигнала — старые буи; заранее отличить их нельзя."
    }
  }
  var next: CampaignMission? {
    switch self {
    case .aster: .currentStation
    case .currentStation: .silentSignal
    case .silentSignal: nil
    }
  }
  var successStory: String {
    switch self {
    case .aster:
      "Ящик «Астера» на базе. В журнале нашли координаты станции: ей нужно оборудование связи."
    case .currentStation:
      "Станция снова на связи, экипаж дома. Пришёл сигнал пропавшего аппарата «Луч»."
    case .silentSignal:
      "«Луч» на базе. Три района открыты — возвращайся за находками и улучшай результат."
    }
  }
  var level: OceanLevel {
    switch self {
    case .aster: .expedition
    case .currentStation: .currentStation
    case .silentSignal: .silentSignal
    }
  }
}

struct CampaignProgress: Codable {
  static let storageKey = "podlodkaDive.campaign.v1"
  static let legacyBestKey = "podlodkaDive.expedition.bestSalvage"
  var selected: CampaignMission = .aster
  var completed: Set<CampaignMission> = []
  var bestScores: [String: Int] = [:]

  func isUnlocked(_ mission: CampaignMission) -> Bool {
    switch mission {
    case .aster: true
    case .currentStation: completed.contains(.aster)
    case .silentSignal: completed.contains(.aster) && completed.contains(.currentStation)
    }
  }

  static func load(from defaults: UserDefaults) -> CampaignProgress {
    if let data = defaults.data(forKey: storageKey) {
      var progress = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
      progress.completed = Set(progress.completed.filter { progress.isUnlocked($0) })
      if !progress.isUnlocked(progress.selected) { progress.selected = .aster }
      progress.bestScores = progress.bestScores.mapValues { max(0, $0) }
      return progress
    }
    var progress = Self()
    let oldBest = defaults.integer(forKey: legacyBestKey)
    if oldBest >= 600 {
      progress.completed.insert(.aster)
      progress.bestScores[CampaignMission.aster.rawValue] = oldBest
    }
    progress.save(to: defaults)
    return progress
  }

  func save(to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
  }

  mutating func complete(_ mission: CampaignMission, score: Int) {
    completed.insert(mission)
    bestScores[mission.rawValue] = max(bestScores[mission.rawValue] ?? 0, score)
  }
}

enum ExpeditionOutcome: String {
  case completed, returned, gameOver, abandoned
}

struct SearchSignal: Codable, Identifiable, Equatable {
  enum Finding: String, Codable { case unknown, buoy, drone }
  let id: Int
  let position: CGPoint
  var finding: Finding = .unknown
  var name: String { "Сигнал \(["A", "B", "C"][id])" }
  var label: String {
    switch finding {
    case .unknown: name + " · не проверен"
    case .buoy: name + " · старый буй"
    case .drone: "Аппарат «Луч»"
    }
  }
}

struct MissionRun: Codable {
  static let scanRadius: CGFloat = 220
  let mission: CampaignMission
  private let realSignalIndex: Int
  var signals: [SearchSignal]
  var equipmentDelivered = false
  var droneRecovered = false
  var returningEarly = false
  var currentHintShown = false

  init(mission: CampaignMission, randomValue: Double) {
    self.mission = mission
    let value = randomValue.isFinite ? min(0.999999, max(0, randomValue)) : 0
    realSignalIndex = Int(value * 3)
    signals =
      mission == .silentSignal
      ? [
        SearchSignal(id: 0, position: CGPoint(x: 280, y: 850)),
        SearchSignal(id: 1, position: CGPoint(x: 1270, y: 1060)),
        SearchSignal(id: 2, position: CGPoint(x: 780, y: 1950)),
      ] : []
  }

  var foundDrone: SearchSignal? { signals.first { $0.finding == .drone } }
  var checkedCount: Int { signals.filter { $0.finding != .unknown }.count }
  func nearestUnidentified(to position: CGPoint) -> SearchSignal? {
    signals.filter { $0.finding == .unknown }.min {
      let left = hypot($0.position.x - position.x, $0.position.y - position.y)
      let right = hypot($1.position.x - position.x, $1.position.y - position.y)
      return left == right ? $0.id < $1.id : left < right
    }
  }
  mutating func scan(from position: CGPoint) -> SearchSignal? {
    guard foundDrone == nil, let signal = nearestUnidentified(to: position),
      hypot(signal.position.x - position.x, signal.position.y - position.y) < Self.scanRadius
    else {
      return nil
    }
    signals[signal.id].finding = signal.id == realSignalIndex ? .drone : .buoy
    return signals[signal.id]
  }
}

struct MissionLandmark: Identifiable {
  enum Kind { case wreck, station, signal, buoy, drone, recovered }
  let id: String
  let position: CGPoint
  let label: String
  let kind: Kind
}
