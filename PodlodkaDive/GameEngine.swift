import Combine
import Foundation
import QuartzCore
import UIKit

enum RunState: Codable, Equatable { case ready, playing, paused, gameOver, completed }
enum FailureReason: Codable { case hull, energy }
enum PickupKind: String, Codable { case battery, shield, sample, blackBox, crystal }
enum MinePhase: Codable { case idle, armed, exploding, spent }
enum DiveZone: Codable, Equatable { case ocean, bossCave }
enum BossStrikePhase: Codable { case warning, impact }

struct OceanPortal: Codable {
    let position: CGPoint
}

struct BossStrike: Codable {
    let position: CGPoint
    var phase: BossStrikePhase = .warning
    var timer: TimeInterval
}

enum AccessibilityContactKind: String, CaseIterable {
    case target, base, mine, reef, battery, shield, sample, crystal, portal, boss, tentacle
}

struct AccessibilityContact: Identifiable, Equatable {
    let id: String
    let kind: AccessibilityContactKind
    let distanceMeters: Int
    let clockHour: Int
    var name: String? = nil
}

enum AccessibilityNavigation {
    static func distanceMeters(from origin: CGPoint, to destination: CGPoint) -> Int {
        Int(hypot(destination.x - origin.x, destination.y - origin.y) * 0.16)
    }

    static func nearestPoint(on rock: OceanRock, to position: CGPoint) -> CGPoint {
        rock.vertices.indices.map { index in
            let a = rock.vertices[index], b = rock.vertices[(index + 1) % rock.vertices.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((position.x - a.x) * dx + (position.y - a.y) * dy)
                / max(0.001, dx * dx + dy * dy)))
            return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        }.min { hypot($0.x - position.x, $0.y - position.y) < hypot($1.x - position.x, $1.y - position.y) } ?? position
    }

    /// Screen coordinates: twelve o'clock is up (negative Y), then clockwise.
    static func clockHour(from origin: CGPoint, to destination: CGPoint) -> Int {
        let angle = atan2(destination.x - origin.x, -(destination.y - origin.y))
        let normalized = angle >= 0 ? angle : angle + 2 * .pi
        let tick = Int((normalized / (2 * .pi) * 12).rounded()) % 12
        return tick == 0 ? 12 : tick
    }
}

enum A11yL10n {
    static func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    static func format(_ key: StaticString, defaultValue: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(format: String(localized: key, defaultValue: defaultValue), locale: .current, arguments: arguments)
    }

    static func contactKind(_ kind: AccessibilityContactKind) -> String {
        switch kind {
        case .target: text("a11y.contact.target", defaultValue: "Цель")
        case .base: text("a11y.contact.base", defaultValue: "База")
        case .mine: text("a11y.contact.mine", defaultValue: "Мина")
        case .reef: text("a11y.contact.reef", defaultValue: "Риф")
        case .battery: text("a11y.contact.battery", defaultValue: "Батарея")
        case .shield: text("a11y.contact.shield", defaultValue: "Щит")
        case .sample: text("a11y.contact.sample", defaultValue: "Образец")
        case .crystal: text("a11y.contact.crystal", defaultValue: "Кристалл")
        case .portal: text("a11y.contact.portal", defaultValue: "Портал")
        case .boss: text("a11y.contact.boss", defaultValue: "Спрут")
        case .tentacle: text("a11y.contact.tentacle", defaultValue: "Удар щупальца")
        }
    }

    static func pickupName(_ kind: PickupKind) -> String {
        switch kind {
        case .battery: contactKind(.battery)
        case .shield: contactKind(.shield)
        case .sample: contactKind(.sample)
        case .crystal: contactKind(.crystal)
        case .blackBox: text("a11y.blackbox", defaultValue: "Чёрный ящик")
        }
    }

    static func contact(_ contact: AccessibilityContact) -> String {
        format("a11y.contact.format", defaultValue: "%@, %lld метров, на %lld часов",
               (contact.name ?? contactKind(contact.kind)), Int64(contact.distanceMeters), Int64(contact.clockHour))
    }
}

enum SubmarineStyle: String, CaseIterable, Codable, Identifiable {
    case classic, neon, flames, chrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Классика"
        case .neon: return "Неоновая глубина"
        case .flames: return "Огненный рейс"
        case .chrome: return "Хром и бас"
        }
    }
    var price: Int {
        switch self { case .classic: return 0; case .neon: return 20; case .flames: return 40; case .chrome: return 60 }
    }
    var description: String {
        switch self {
        case .classic: return "Золотистый корпус с круглыми иллюминаторами."
        case .neon: return "Фиолетовый корпус, бирюзовая неоновая окантовка и подсветка днища."
        case .flames: return "Красный корпус с золотыми языками пламени вдоль борта."
        case .chrome: return "Серебристый хромированный корпус и две большие колонки на крыше."
        }
    }
}

/// A single saved value keeps the wallet, purchases and selection together.
private struct GarageSave: Codable {
    var crystals = 0
    var unlocked: Set<SubmarineStyle> = [.classic]
    var selected: SubmarineStyle = .classic
}

struct OceanPickup: Identifiable, Codable {
    let id: Int
    let kind: PickupKind
    let position: CGPoint
    var collected = false
}

struct OceanMine: Identifiable, Codable {
    let id: Int
    let position: CGPoint
    var phase: MinePhase = .idle
    var timer: TimeInterval = 0
    static let triggerRadius: CGFloat = 120
    static let blastRadius: CGFloat = 96
    static let fuse: TimeInterval = 1.25
}

struct OceanCurrent: Identifiable, Codable {
    let id: Int
    let bounds: CGRect
    let velocity: CGVector
}

struct RockContact {
    let normal: CGVector
    let penetration: CGFloat
}

struct OceanRock: Identifiable, Codable {
    let id: Int
    let vertices: [CGPoint]

    var bounds: CGRect {
        guard let first = vertices.first else { return .zero }
        let xs = vertices.map(\.x), ys = vertices.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                      width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                      height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }

    /// Circle against the exact polygon also handles corners and starting inside.
    func contact(at point: CGPoint, radius: CGFloat) -> RockContact? {
        guard vertices.count >= 3, bounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return nil }
        var inside = false
        var closest = vertices[0]
        var nearestSquared = CGFloat.infinity
        var edgeNormal = CGVector(dx: 1, dy: 0)
        var area: CGFloat = 0
        for index in vertices.indices {
            let a = vertices[index], b = vertices[(index + 1) % vertices.count]
            area += a.x * b.y - b.x * a.y
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
            let candidate = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let d = pow(point.x - candidate.x, 2) + pow(point.y - candidate.y, 2)
            if d < nearestSquared {
                closest = candidate
                nearestSquared = d
                let length = max(0.001, sqrt(lengthSquared))
                edgeNormal = CGVector(dx: dy / length, dy: -dx / length)
            }
        }
        let distance = sqrt(nearestSquared)
        guard inside || distance < radius else { return nil }
        let sign: CGFloat = inside ? -1 : 1
        let normal = distance > 0.001
            ? CGVector(dx: (point.x - closest.x) / distance * sign, dy: (point.y - closest.y) / distance * sign)
            : CGVector(dx: edgeNormal.dx * (area >= 0 ? 1 : -1), dy: edgeNormal.dy * (area >= 0 ? 1 : -1))
        return RockContact(normal: normal, penetration: inside ? radius + distance : radius - distance)
    }
}


enum CompassCourse: Int, CaseIterable, Equatable {
    case n, ne, e, se, s, sw, w, nw
    var label: String {
        [A11yL10n.text("a11y.course.north", defaultValue: "север"),
         A11yL10n.text("a11y.course.northeast", defaultValue: "северо-восток"),
         A11yL10n.text("a11y.course.east", defaultValue: "восток"),
         A11yL10n.text("a11y.course.southeast", defaultValue: "юго-восток"),
         A11yL10n.text("a11y.course.south", defaultValue: "юг"),
         A11yL10n.text("a11y.course.southwest", defaultValue: "юго-запад"),
         A11yL10n.text("a11y.course.west", defaultValue: "запад"),
         A11yL10n.text("a11y.course.northwest", defaultValue: "северо-запад")][rawValue]
    }
    var vector: CGVector { steeringVector(for: self) }
    init(vector: CGVector) {
        let angle = atan2(vector.dx, -vector.dy)
        self = Self(rawValue: (Int((angle / (.pi / 4)).rounded()) + 8) % 8)!
    }
}

func steeringVector(for course: CompassCourse) -> CGVector {
    let angle = CGFloat(course.rawValue) * .pi / 4
    return CGVector(dx: sin(angle), dy: -cos(angle))
}

struct SituationSummary: Equatable {
    struct Contact: Equatable {
        let id: String
        let name: String
        let distance: Int
        let course: CompassCourse
    }
    var zone: String = "ocean"
    var position: CGPoint = .zero
    var energy: CGFloat = 100
    var hull: Int = 3
    var targetName: String? = nil
    let depth: Int
    let speed: Int
    let returning: Bool
    let targetDistance: Int
    let targetCourse: CompassCourse
    let danger: Contact?
    let find: Contact?
    let currentCourse: CompassCourse?
    let currentSpeed: Int
    let caveTimeRemaining: Int?
}

enum GameEvent: Equatable {
    case runStarted(UUID)
    case runEnded(String)
    case diagnostic(BlackBoxLevel, BlackBoxCategory, String, [String: String])
    case speak(String)
    case danger(String)
    case energyLow
    case stateChanged(RunState)
    case objectiveChanged(Bool)
    case success(Int)
    case record(Int)
    case situation(SituationSummary)
}

/// A bounded, session-local historical record written on events and periodic reports.
struct ExpeditionLogEntry: Identifiable {
    enum Level: String { case event = "Событие", warning = "Опасность", error = "Ошибка", state = "Состояние" }
    let id = UUID()
    let date = Date()
    let expedition: Int
    let seconds: TimeInterval
    let level: Level
    let message: String
    let snapshot: String
    let crewPhrase: String?
}

@MainActor
final class CrewEventLog {
    private(set) var entries: [ExpeditionLogEntry] = []
    static let capacity = 500

    func record(expedition: Int, seconds: TimeInterval, level: ExpeditionLogEntry.Level,
                message: String, snapshot: String, crewPhrase: String? = nil) {
        entries.append(ExpeditionLogEntry(expedition: expedition, seconds: seconds,
                                          level: level, message: message, snapshot: snapshot, crewPhrase: crewPhrase))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

struct JournalLeak {
    let phrase: String
    let startedAt: TimeInterval
    let side: CGFloat
}

@MainActor
final class GameEngine: NSObject, ObservableObject {
    private(set) var expeditionId: String?
    private let telemetryLogger: ExpeditionLogger
    private var telemetryOpen = false
    private var journalTask: Task<Void, Never>?
    private var lastSnapshotTime: Double = -1
    private var lastSteeringTime: Double = -1
    private var journalScreen = "Welcome"

    func journal(_ type: String, _ extra: [String: String] = [:]) {
        guard telemetryOpen, let id = expeditionId else { return }
        var payload = journalState
        payload.merge(extra) { _, new in new }
        let prior = journalTask
        journalTask = Task {
            await prior?.value
            await telemetryLogger.log(expeditionId: id, type: type,
                category: type == "snapshot" ? "State" : (type == "error" ? "Errors" : "Gameplay"),
                severity: type == "error" ? "error" : "info", payload: payload)
        }
    }

    private var journalState: [String: String] {
        ["time": String(runElapsed), "x": String(Double(position.x)), "y": String(Double(position.y)),
         "vx": String(Double(velocity.dx)), "vy": String(Double(velocity.dy)),
         "heading": String(Double(atan2(velocity.dy, velocity.dx))), "energy": String(Double(energy)),
         "hull": String(hull), "cargo": String(cargoValue), "samples": String(samples),
         "blackBox": String(hasBlackBox), "shield": String(hasShield), "target": targetLabel,
         "missionID": mission?.rawValue ?? CampaignMission.aster.rawValue,
         "missionTitle": mission?.title ?? CampaignMission.aster.title,
         "mapVersion": "1", "objectiveReady": String(objectiveReady),
         "missionPhase": missionPhase, "outcome": outcome?.rawValue ?? "inProgress",
         "signals": (missionRun?.signals ?? []).map { "\($0.id),\($0.finding.rawValue),\($0.position.x),\($0.position.y)" }.joined(separator: ";"),
         "targetX": String(Double(target.x)), "targetY": String(Double(target.y)),
         "zone": String(describing: zone), "width": String(Double(zone == .ocean ? level.size.width : Self.caveSize.width)),
         "height": String(Double(zone == .ocean ? level.size.height : Self.caveSize.height)),
         "pickups": pickups.filter { !$0.collected }.map { "\($0.id),\($0.kind.rawValue),\($0.position.x),\($0.position.y)" }.joined(separator: ";"),
         "mines": mines.map { "\($0.id),\($0.phase),\($0.position.x),\($0.position.y),\($0.timer)" }.joined(separator: ";"),
         "rocks": level.rocks.map { $0.vertices.map { "\($0.x),\($0.y)" }.joined(separator: ":") }.joined(separator: ";"),
         "bossTime": String(bossTimeRemaining), "bossDefeated": String(bossDefeated),
         "boost": String(boostRemaining), "sonar": String(sonarRemaining)]
    }

    func navigate(to screen: String, reason: String) {
        guard screen != journalScreen else { return }
        journal("navigation", ["fromScreen": journalScreen, "toScreen": screen, "reason": reason])
        journalScreen = screen
    }

    func flushJournal() async {
        await journalTask?.value
        await telemetryLogger.flush()
        receiptJournal.flush()
        captainLogger.flush()
    }

    private func endJournal(result: String, reason: String) {
        guard telemetryOpen else { return }
        journal("end", ["result": result, "reason": reason])
        telemetryOpen = false
        events.send(.runEnded(result))
    }

    private let receiptJournal: any ExpeditionLogging
    private(set) var diveID: UUID?
    private var journalOpen = false
    private var nextSnapshot: TimeInterval = 5

    private func log(_ kind: String, _ message: String, severity: String = "info") {
        guard journalOpen, let diveID else { return }
        receiptJournal.record(JournalEntry(id: UUID(), diveID: diveID, date: Date(), elapsed: runElapsed,
            kind: kind, severity: severity, message: message,
            boat: BoatSnapshot(x: Double(position.x), y: Double(position.y), energy: Double(energy),
                hull: hull, cargo: cargoValue, blackBox: hasBlackBox, shield: hasShield,
                zone: String(describing: zone), state: String(describing: state), speed: Double(speed),
                missionID: mission?.rawValue, missionPhase: missionPhase)))
    }

    private func closeJournal(_ outcome: String, severity: String = "info") {
        log("finish", outcome, severity: severity)
        journalOpen = false
        receiptJournal.flush()
    }

    let captainLogger: CaptainLogger
    private var expeditionID = UUID()
    let events = PassthroughSubject<GameEvent, Never>()
    let crewJournal = CrewEventLog()
    private(set) var expeditionNumber = 0
    private(set) var journalLeak: JournalLeak?
    private var nextLeakAt: TimeInterval = 0
    private var nextSnapshotAt: TimeInterval = 15
    private var leakOnLeft = false

    private func log(_ message: String, level: ExpeditionLogEntry.Level = .event, phrase: String? = nil) {
        crewJournal.record(expedition: expeditionNumber, seconds: runElapsed, level: level,
                       message: message, snapshot: "\(state) · \(zone) · \(accessibilityStatus)", crewPhrase: phrase)
        if let phrase, state == .playing, runElapsed >= nextLeakAt {
            leakOnLeft.toggle()
            journalLeak = JournalLeak(phrase: phrase, startedAt: runElapsed, side: leakOnLeft ? -1 : 1)
            nextLeakAt = runElapsed + 8
        }
    }

    @Published private(set) var state: RunState = .ready {
        didSet {
            if oldValue != state {
                events.send(.stateChanged(state))
                log("state", "Режим: \(state)")
                logWatch("state", "Состояние: \(oldValue) → \(state)")
                captainLogger.flush()
            }
        }
    }
    private var dockingTooFast = false
    private var didWarnEnergy = false
    private var summaryTicks = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var bestScore: Int
    @Published private(set) var pickupCount = 0
    @Published private(set) var damageCount = 0
    @Published private(set) var accessibilityAnnouncementRevision = 0
    @Published private(set) var eventCount = 0

    @Published private var garage: GarageSave
    private(set) var garageLoadError: String?
    private static let garageKey = "podlodkaDive.garage.v1"
    var crystals: Int { garage.crystals }
    var selectedStyle: SubmarineStyle { garage.selected }

    private(set) var level: OceanLevel
    let isCampaign: Bool
    @Published private(set) var campaignProgress: CampaignProgress
    private(set) var missionRun: MissionRun?
    private(set) var outcome: ExpeditionOutcome?
    var mission: CampaignMission? { isCampaign ? campaignProgress.selected : nil }
    private(set) var viewport = CGSize(width: 390, height: 844)
    private(set) var position: CGPoint
    private(set) var velocity = CGVector.zero
    private(set) var steering = CGVector.zero
    private(set) var camera = CGPoint.zero
    private(set) var facing: CGFloat = 1
    private(set) var energy: CGFloat = 100
    private(set) var hull = 3
    private(set) var hasShield = false
    private(set) var hasBlackBox = false
    private(set) var samples = 0
    private(set) var score = 0
    private(set) var bestAtStart = 0
    private(set) var runElapsed: TimeInterval = 0
    private(set) var distance: CGFloat = 0
    private(set) var boostRemaining: TimeInterval = 0
    private(set) var boostCooldown: TimeInterval = 0
    private(set) var lightBoostRemaining: TimeInterval = 0
    private(set) var lightBoostCooldown: TimeInterval = 0
    private(set) var sonarRemaining: TimeInterval = 0
    private(set) var sonarCooldown: TimeInterval = 0
    private(set) var invulnerability: TimeInterval = 0
    private(set) var pickups: [OceanPickup]
    private(set) var mines: [OceanMine]
    private(set) var revealedPickups: Set<Int> = []
    private(set) var trail: [CGPoint] = []
    private(set) var notice = ""
    private(set) var noticeRemaining: TimeInterval = 0
    private(set) var failureReason: FailureReason = .hull
    private(set) var zone: DiveZone = .ocean
    private(set) var portal: OceanPortal?
    private(set) var portalRevealed = false
    private(set) var bossStrike: BossStrike?
    private(set) var bossTimeRemaining: TimeInterval = 0
    private(set) var bossDefeated = false
    private(set) var bossReward = 0

    private var boostDirection = CGVector(dx: 1, dy: 0)
    private var accessibilityMoveRemaining: TimeInterval = 0
    private var bossStrikeCooldown: TimeInterval = 0
    private var portalReturnPosition = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var accumulator: TimeInterval = 0
    private var announcedCriticalHull = false
    private var announcedDockingHint = false
    private let defaults: UserDefaults
    private let randomValue: () -> Double
    private static let bestKey = CampaignProgress.legacyBestKey
    static let hullRadius: CGFloat = 20
    static let cruiseSpeed: CGFloat = 96
    static let boostCost: CGFloat = 7
    static let portalChance = 0.4
    static let bossDuration: TimeInterval = 24
    static let caveSize = CGSize(width: 780, height: 1000)
    static let lightBoostCost: CGFloat = 5
    static let lightBoostDuration: TimeInterval = 4
    static let lightBoostRecharge: TimeInterval = 10
    private static let fixedStep: TimeInterval = 1.0 / 120.0

    init(defaults: UserDefaults = .standard, level: OceanLevel? = nil,
         telemetryLogger: ExpeditionLogger = .shared,
         journal: any ExpeditionLogging = ExpeditionJournal.shared,
         captainLogger: CaptainLogger = .shared,
         randomValue: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        var saved = GarageSave()
        if let data = defaults.data(forKey: Self.garageKey) {
            do { saved = try JSONDecoder().decode(GarageSave.self, from: data) }
            catch { garageLoadError = error.localizedDescription }
        }
        saved.crystals = max(0, saved.crystals)
        saved.unlocked.insert(.classic)
        if !saved.unlocked.contains(saved.selected) { saved.selected = .classic }
        garage = saved
        self.telemetryLogger = telemetryLogger
        self.receiptJournal = journal
        self.captainLogger = captainLogger
        self.defaults = defaults
        let progress = CampaignProgress.load(from: defaults)
        campaignProgress = progress
        isCampaign = level == nil
        let world = level ?? progress.selected.level
        self.level = world
        self.randomValue = randomValue
        position = world.spawn
        pickups = world.pickups
        mines = world.mines
        bestScore = level == nil ? (progress.bestScores[progress.selected.rawValue] ?? 0)
            : defaults.integer(forKey: Self.bestKey)
        super.init()
        updateCamera(dt: 1, snap: true)
    }

    var speed: CGFloat { hypot(velocity.dx, velocity.dy) }
    var inputStrength: CGFloat { hypot(steering.dx, steering.dy) }
    var isThrustActive: Bool { state == .playing && (inputStrength > 0 || boostRemaining > 0) }
    var cargoValue: Int { samples * 75 + (objectiveReady ? 600 : 0) + bossReward }
    var depth: Int { Int(max(0, position.y - 100) * 0.16) }
    var target: CGPoint {
        if zone == .bossCave { return CGPoint(x: Self.caveSize.width / 2, y: 145) }
        if returningToBase { return level.base }
        if mission == .silentSignal, let run = missionRun {
            return run.foundDrone?.position ?? run.nearestUnidentified(to: position)?.position ?? level.base
        }
        return level.wreck
    }
    var targetDistance: Int { Int(hypot(target.x - position.x, target.y - position.y) * 0.16) }
    var isNewRecord: Bool { outcome == .completed && score > bestAtStart }
    var canBoost: Bool { state == .playing && boostCooldown <= 0 && energy >= Self.boostCost }
    var canLightBoost: Bool { state == .playing && lightBoostCooldown <= 0 && energy >= Self.lightBoostCost }
    var isLightBoostActive: Bool { lightBoostRemaining > 0 }
    var headlightRange: CGFloat { isLightBoostActive ? 520 : 255 }
    var canSonar: Bool { state == .playing && sonarCooldown <= 0 }
    var submarineRotationRadians: Double { Double(atan2(velocity.dy, max(55, abs(velocity.dx)))) * 0.55 }
    var targetClockHour: Int { AccessibilityNavigation.clockHour(from: position, to: target) }

    var sonarContacts: [AccessibilityContact] {
        func contact(id: String, kind: AccessibilityContactKind, point: CGPoint) -> AccessibilityContact {
            AccessibilityContact(id: id, kind: kind,
                                 distanceMeters: AccessibilityNavigation.distanceMeters(from: position, to: point),
                                 clockHour: AccessibilityNavigation.clockHour(from: position, to: point))
        }

        if zone == .bossCave {
            var contacts = [contact(id: "boss", kind: .boss, point: target)]
            if let bossStrike, bossStrike.phase == .warning {
                contacts.append(contact(id: "tentacle", kind: .tentacle, point: bossStrike.position))
            }
            return contacts
        }
        var targetContact = contact(id: "target", kind: .target, point: target)
        targetContact.name = targetLabel
        var contacts = [targetContact, contact(id: "base", kind: .base, point: level.base)]
        if mission == .silentSignal {
            contacts += (missionRun?.signals ?? []).filter {
                !($0.finding == .drone && missionRun?.droneRecovered == true)
            }.map { signal in
                var value = contact(id: "signal-\(signal.id)", kind: .target, point: signal.position)
                value.name = signal.label
                return value
            }
        }
        contacts += mines.filter { mine in
            mine.phase != .spent && hypot(mine.position.x - position.x, mine.position.y - position.y) <= 400
        }.map { contact(id: "mine-\($0.id)", kind: .mine, point: $0.position) }
        contacts += level.rocks.compactMap { rock in
            let nearest = AccessibilityNavigation.nearestPoint(on: rock, to: position)
            guard hypot(nearest.x - position.x, nearest.y - position.y) <= 400 else { return nil }
            return contact(id: "reef-\(rock.id)", kind: .reef, point: nearest)
        }
        contacts += pickups.filter { pickup in
            !pickup.collected && pickup.kind != .blackBox && revealedPickups.contains(pickup.id)
        }.map { pickup in
            let kind: AccessibilityContactKind = switch pickup.kind {
            case .battery: .battery
            case .shield: .shield
            case .sample: .sample
            case .crystal: .crystal
            case .blackBox: .target
            }
            return contact(id: "pickup-\(pickup.id)", kind: kind, point: pickup.position)
        }
        if let portal, portalRevealed {
            contacts.append(contact(id: "portal", kind: .portal, point: portal.position))
        }
        return contacts.sorted {
            if $0.distanceMeters == $1.distanceMeters { return $0.id < $1.id }
            return $0.distanceMeters < $1.distanceMeters
        }
    }

    var sectorOverview: String {
        if zone == .bossCave { return accessibilityStatus + ". " + accessibilitySurroundings }
        let objective: String
        if (mission == nil || mission == .aster) && missionRun?.returningEarly != true {
            objective = hasBlackBox
                ? A11yL10n.text("a11y.objective.base", defaultValue: "Доставить чёрный ящик на базу")
                : A11yL10n.text("a11y.objective.blackbox", defaultValue: "Найти чёрный ящик")
        } else {
            objective = objectiveText
        }
        let nearby = sonarContacts.prefix(3).map(A11yL10n.contact).joined(separator: "; ")
        let remaining = pickups.filter { !$0.collected }.count
        let flows = level.currents.map {
            "Течение \(AccessibilityNavigation.clockHour(from: .zero, to: CGPoint(x: $0.velocity.dx, y: $0.velocity.dy))) часов"
        }.joined(separator: ". ")
        return A11yL10n.format("a11y.map.overview.format",
                               defaultValue: "Обзор сектора. Цель: %@. Ближайшие контакты: %@. Осталось находок: %lld.",
                               objective, nearby, Int64(remaining)) + ". " + flows
            + (mission == .silentSignal ? ". " + (missionRun?.signals ?? []).map {
                "\($0.finding == .drone && missionRun?.droneRecovered == true ? "Место находки — аппарат на борту" : $0.label), \(directionAndDistance(to: $0.position))"
            }.joined(separator: ". ") : "")
    }
    var worldSize: CGSize { zone == .bossCave ? Self.caveSize : level.size }
    var objectiveText: String {
        if zone == .bossCave { return "Переживи нападение · \(Int(ceil(bossTimeRemaining))) с" }
        if returningToBase { return objectiveReady ? "Вернись на базу" : "Курс на базу · задание не выполнено" }
        switch mission {
        case .currentStation: return "Доставь оборудование на станцию"
        case .silentSignal:
            return missionRun?.foundDrone == nil ? "Проверь сигналы сонаром" : "Подбери аппарат «Луч»"
        default: return "Найди чёрный ящик"
        }
    }

    var accessibilityStatus: String {
        let shield = hasShield ? " Щит активен." : ""
        if zone == .bossCave {
            return "Пещера спрута. Осталось \(Int(ceil(bossTimeRemaining))) секунд. Корпус \(hull) из 3. Энергия \(Int(energy)) процентов.\(shield)"
        }
        return "Глубина \(depth) метров. Корпус \(hull) из 3. Энергия \(Int(energy)) процентов. Груз \(cargoValue).\(shield)"
    }

    var accessibilitySurroundings: String {
        if zone == .bossCave {
            if let bossStrike, bossStrike.phase == .warning {
                return "Щупальце ударит \(directionAndDistance(to: bossStrike.position)). Уклоняйтесь."
            }
            return "Спрут впереди. Следующий удар ещё не обозначен."
        }
        var parts = ["\(targetLabel) \(directionAndDistance(to: target))."]
        if let portal, portalRevealed {
            parts.append("Портал в пещеру \(directionAndDistance(to: portal.position)).")
        }
        if let mine = mines.filter({ $0.phase != .spent }).min(by: {
            hypot($0.position.x - position.x, $0.position.y - position.y) < hypot($1.position.x - position.x, $1.position.y - position.y)
        }), hypot(mine.position.x - position.x, mine.position.y - position.y) < 420 {
            parts.append("Ближайшая мина \(directionAndDistance(to: mine.position)).")
        }
        return parts.joined(separator: " ")
    }

    var objectiveReady: Bool {
        switch mission {
        case .currentStation: missionRun?.equipmentDelivered == true
        case .silentSignal: missionRun?.droneRecovered == true
        default: hasBlackBox
        }
    }
    var returningToBase: Bool { objectiveReady || missionRun?.returningEarly == true }
    var targetLabel: String {
        if zone == .bossCave { return "Спрут" }
        if returningToBase { return "База" }
        switch mission {
        case .currentStation: return "Станция «Течение»"
        case .silentSignal:
            return missionRun?.foundDrone?.label
                ?? missionRun?.nearestUnidentified(to: position)?.name ?? "Сигналы"
        default: return A11yL10n.pickupName(.blackBox)
        }
    }
    var missionLandmarks: [MissionLandmark] {
        if mission == .silentSignal {
            return (missionRun?.signals ?? []).map {
                MissionLandmark(id: "signal-\($0.id)", position: $0.position,
                    label: $0.finding == .drone && missionRun?.droneRecovered == true ? "Место находки · аппарат на борту" : $0.label,
                    kind: $0.finding == .drone && missionRun?.droneRecovered == true ? .recovered
                        : ($0.finding == .drone ? .drone : ($0.finding == .buoy ? .buoy : .signal)))
            }
        }
        return [MissionLandmark(id: "destination", position: level.wreck,
                               label: mission == .currentStation ? "Станция «Течение»" : "Астер",
                               kind: mission == .currentStation ? .station : .wreck)]
    }
    var missionPhase: String {
        if outcome != nil { return outcome!.rawValue }
        if objectiveReady { return "returnWithObjective" }
        if missionRun?.returningEarly == true { return "returnEarly" }
        if mission == .silentSignal { return missionRun?.foundDrone == nil ? "search" : "recoverDrone" }
        return mission == .currentStation ? "deliverEquipment" : "recoverBlackBox"
    }
    var missionMetadata: [String: String] {
        ["missionID": mission?.rawValue ?? CampaignMission.aster.rawValue,
         "missionTitle": mission?.title ?? CampaignMission.aster.title,
         "mapVersion": "1", "phase": missionPhase]
    }
    var missionStatus: String {
        if returningToBase && !objectiveReady { return "Возвращаемся без выполнения задания" }
        switch mission {
        case .currentStation: return objectiveReady ? "Оборудование доставлено" : "Оборудование на борту"
        case .silentSignal:
            if objectiveReady { return "Аппарат на борту" }
            if missionRun?.foundDrone == nil, let signal = missionRun?.nearestUnidentified(to: position),
               hypot(signal.position.x - position.x, signal.position.y - position.y) < MissionRun.scanRadius {
                return "Сигнал рядом — включи сонар"
            }
            return "Проверено \(missionRun?.checkedCount ?? 0) из 3 сигналов"
        default: return hasBlackBox ? "Ящик на борту" : "Ящик ещё на «Астере»"
        }
    }
    var resultDetail: String {
        if outcome == .returned {
            return "Добыча на базе. Задание не выполнено, следующая экспедиция не открыта. Можно попробовать снова."
        }
        return mission?.successStory ?? "Чёрный ящик на базе. Хорошая работа, капитан."
    }

    @discardableResult
    func selectMission(_ mission: CampaignMission) -> Bool {
        guard isCampaign, state == .ready, campaignProgress.isUnlocked(mission) else { return false }
        campaignProgress.selected = mission
        campaignProgress.save(to: defaults)
        level = mission.level
        missionRun = nil
        outcome = nil
        hasBlackBox = false
        position = level.spawn
        pickups = level.pickups
        mines = level.mines
        bestScore = campaignProgress.bestScores[mission.rawValue] ?? 0
        updateCamera(dt: 1, snap: true)
        objectWillChange.send()
        return true
    }

    func setReturnToBase(_ requested: Bool) {
        guard isCampaign, (state == .playing || state == .paused), zone == .ocean,
              !objectiveReady, missionRun?.returningEarly != requested else { return }
        missionRun?.returningEarly = requested
        steering = .zero
        accessibilityMoveRemaining = 0
        recordMission(requested ? "return.requested" : "return.cancelled",
                      requested ? "Курс на базу. Остановись в круге базы, чтобы сохранить добычу."
                          : "Продолжаем задание. Найденные контакты сохранены.")
        objectWillChange.send()
    }

    private func recordMission(_ kind: String, _ message: String, extra: [String: String] = [:]) {
        let fields = missionMetadata.merging(extra) { _, new in new }
        journal(kind, fields)
        log(kind, message)
        logWatch(kind, message)
        log(message)
        events.send(.diagnostic(.info, .event, kind, fields))
        announce(message, duration: 6)
    }

    @discardableResult
    private func scanMissionSignal() -> Bool {
        guard zone == .ocean, let signal = missionRun?.scan(from: position) else { return false }
        let message = signal.finding == .drone
            ? "\(signal.name): найден аппарат «Луч». Подойди, чтобы взять его на борт."
            : "\(signal.name): старый буй. Проверь следующий сигнал."
        recordMission("signal.checked", message,
                      extra: ["signal": String(signal.id), "finding": signal.finding.rawValue])
        return true
    }

    private func updateMission() {
        if sonarRemaining > 0 { scanMissionSignal() }
        if mission == .currentStation, missionRun?.equipmentDelivered == false,
           hypot(position.x - level.wreck.x, position.y - level.wreck.y) < 68, speed < 48 {
            missionRun?.equipmentDelivered = true
            recordMission("equipment.delivered", "Станция снова на связи. Вернись на базу: на западной стороне поток идёт к дому.")
        }
        if mission == .currentStation, missionRun?.currentHintShown == false {
            let flow = current(at: position)
            if hypot(flow.dx, flow.dy) > 30 {
                missionRun?.currentHintShown = true
                recordMission("current.hint", "Поток несёт лодку даже без тяги. Направления течений видны на карте.")
            }
        }
        if mission == .silentSignal, missionRun?.droneRecovered == false,
           let drone = missionRun?.foundDrone, hypot(position.x - drone.position.x, position.y - drone.position.y) < 39 {
            missionRun?.droneRecovered = true
            pickupCount += 1
            recordMission("drone.recovered", "Аппарат «Луч» на борту. Вернись на базу.")
        }
    }

    func owns(_ style: SubmarineStyle) -> Bool { garage.unlocked.contains(style) }

    /// Purchases and equipment changes are allowed only before an expedition.
    @discardableResult
    func customize(_ style: SubmarineStyle) -> String {
        guard state == .ready else { events.send(.diagnostic(.warning, .event, "garage.denied", ["reason": "state"])); return "Открой гараж перед началом экспедиции." }
        let purchased = !owns(style)
        if purchased {
            guard crystals >= style.price else { events.send(.diagnostic(.warning, .resource, "garage.denied", ["reason": "crystals", "style": style.rawValue])); return "Не хватает кристаллов: нужно ещё \(style.price - crystals)." }
            garage.crystals -= style.price
            garage.unlocked.insert(style)
        }
        events.send(.diagnostic(.info, .event, purchased ? "garage.purchase" : "garage.equip", ["style": style.rawValue, "price": String(purchased ? style.price : 0)]))
        garage.selected = style
        saveGarage()
        return "\(purchased ? "Куплено и установлено" : "Установлено"): \(style.title). Баланс: \(crystals) кристаллов."
    }

    private func saveGarage() {
        do { defaults.set(try JSONEncoder().encode(garage), forKey: Self.garageKey) }
        catch { events.send(.diagnostic(.error, .system, "garage.save.failed", ["reason": error.localizedDescription])) }
    }

    func resize(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let next = CGSize(width: 390, height: size.height * 390 / size.width)
        guard next != viewport else { return }
        viewport = next
        pause()
        updateCamera(dt: 1, snap: true)
        objectWillChange.send()
    }


    var recovery: ExpeditionRecovery?
    private var pausedSnapshot: ExpeditionSnapshot?
    private var restoredPause = false

    func snapshot() -> ExpeditionSnapshot {
        if state == .paused, var saved = pausedSnapshot {
            saved.missionRun = missionRun
            return saved
        }
        return ExpeditionSnapshot(id: expeditionID,
            level: level,
            position: position,
            velocity: velocity,
            steering: steering,
            camera: camera,
            facing: facing,
            energy: energy,
            hull: hull,
            hasShield: hasShield,
            hasBlackBox: hasBlackBox,
            samples: samples,
            score: score,
            bestAtStart: bestAtStart,
            runElapsed: runElapsed,
            distance: distance,
            pickups: pickups,
            mines: mines,
            revealedPickups: revealedPickups,
            trail: trail,
            notice: notice,
            failureReason: failureReason,
            zone: zone,
            portal: portal,
            portalRevealed: portalRevealed,
            bossStrike: bossStrike,
            bossDefeated: bossDefeated,
            bossReward: bossReward,
            boostDirection: boostDirection,
            portalReturnPosition: portalReturnPosition,
            announcedCriticalHull: announcedCriticalHull,
            announcedDockingHint: announcedDockingHint,
            dockingTooFast: dockingTooFast,
            didWarnEnergy: didWarnEnergy,
            summaryTicks: summaryTicks,
            pickupCount: pickupCount,
            damageCount: damageCount,
            eventCount: eventCount,
            elapsed: elapsed,
            expeditionNumber: expeditionNumber,
            leakOnLeft: leakOnLeft,
            boostRemaining: boostRemaining,
            boostCooldown: boostCooldown,
            lightBoostRemaining: lightBoostRemaining,
            lightBoostCooldown: lightBoostCooldown,
            sonarRemaining: sonarRemaining,
            sonarCooldown: sonarCooldown,
            invulnerability: invulnerability,
            noticeRemaining: noticeRemaining,
            bossTimeRemaining: bossTimeRemaining,
            accessibilityMoveRemaining: accessibilityMoveRemaining,
            bossStrikeCooldown: bossStrikeCooldown,
            accumulator: accumulator,
            nextLeakAt: nextLeakAt,
            nextSnapshotAt: nextSnapshotAt,
            nextSnapshot: nextSnapshot,
            missionRun: missionRun)
    }

    func restore(_ saved: ExpeditionSnapshot) {
        pausedSnapshot = nil
        restoredPause = true
        missionRun = saved.missionRun ?? (isCampaign ? MissionRun(mission: .aster, randomValue: 0) : nil)
        if let mission = missionRun?.mission {
            campaignProgress.selected = mission
            bestScore = campaignProgress.bestScores[mission.rawValue] ?? 0
            campaignProgress.save(to: defaults)
        }
        outcome = nil
        level = saved.level
        position = saved.position
        velocity = saved.velocity
        steering = saved.steering
        camera = saved.camera
        facing = saved.facing
        energy = saved.energy
        hull = saved.hull
        hasShield = saved.hasShield
        hasBlackBox = saved.hasBlackBox
        samples = saved.samples
        score = saved.score
        bestAtStart = saved.bestAtStart
        runElapsed = saved.runElapsed
        distance = saved.distance
        pickups = saved.pickups
        mines = saved.mines
        revealedPickups = saved.revealedPickups
        trail = saved.trail
        notice = saved.notice
        failureReason = saved.failureReason
        zone = saved.zone
        portal = saved.portal
        portalRevealed = saved.portalRevealed
        bossStrike = saved.bossStrike
        bossDefeated = saved.bossDefeated
        bossReward = saved.bossReward
        boostDirection = saved.boostDirection
        portalReturnPosition = saved.portalReturnPosition
        announcedCriticalHull = saved.announcedCriticalHull
        announcedDockingHint = saved.announcedDockingHint
        dockingTooFast = saved.dockingTooFast
        didWarnEnergy = saved.didWarnEnergy
        summaryTicks = saved.summaryTicks
        pickupCount = saved.pickupCount
        damageCount = saved.damageCount
        eventCount = saved.eventCount
        elapsed = saved.elapsed
        expeditionNumber = saved.expeditionNumber
        leakOnLeft = saved.leakOnLeft
        boostRemaining = saved.boostRemaining
        boostCooldown = saved.boostCooldown
        lightBoostRemaining = saved.lightBoostRemaining
        lightBoostCooldown = saved.lightBoostCooldown
        sonarRemaining = saved.sonarRemaining
        sonarCooldown = saved.sonarCooldown
        invulnerability = saved.invulnerability
        noticeRemaining = saved.noticeRemaining
        bossTimeRemaining = saved.bossTimeRemaining
        accessibilityMoveRemaining = saved.accessibilityMoveRemaining
        bossStrikeCooldown = saved.bossStrikeCooldown
        accumulator = saved.accumulator
        nextLeakAt = saved.nextLeakAt
        nextSnapshotAt = saved.nextSnapshotAt
        nextSnapshot = saved.nextSnapshot
        expeditionID = saved.id
        expeditionId = saved.id.uuidString
        diveID = saved.id
        telemetryOpen = true
        journalOpen = true
        previousTimestamp = nil
        events.send(.runStarted(saved.id))
        state = .paused
        navigate(to: "Pause", reason: "restore")
    }

    func startGame() {
        guard !isCampaign || campaignProgress.isUnlocked(campaignProgress.selected) else { return }
        recovery?.deleteSave()
        pausedSnapshot = nil
        if state == .playing || state == .paused {
            outcome = .abandoned
            endJournal(result: ExpeditionOutcome.abandoned.rawValue, reason: "restart")
        }
        lastSnapshotTime = -1
        lastSteeringTime = -1
        closeJournal("Экспедиция прервана: начато новое погружение")
        expeditionID = UUID()
        expeditionId = expeditionID.uuidString
        diveID = expeditionID
        telemetryOpen = true
        expeditionNumber += 1
        journalLeak = nil
        nextLeakAt = 0
        nextSnapshotAt = 15
        didWarnEnergy = false
        summaryTicks = 0
        zone = .ocean
        if let mission {
            missionRun = MissionRun(mission: mission, randomValue: mission == .silentSignal ? randomValue() : 0)
        }
        outcome = nil
        position = level.spawn
        velocity = .zero
        steering = .zero
        facing = 1
        energy = 100
        hull = 3
        hasShield = false
        hasBlackBox = false
        samples = 0
        score = 0
        bestAtStart = bestScore
        runElapsed = 0
        distance = 0
        boostRemaining = 0
        boostCooldown = 0
        lightBoostRemaining = 0
        lightBoostCooldown = 0
        sonarRemaining = 0
        sonarCooldown = 0
        invulnerability = 0
        accessibilityMoveRemaining = 0
        portal = makePortal()
        portalRevealed = false
        bossStrike = nil
        bossTimeRemaining = 0
        bossStrikeCooldown = 0
        bossDefeated = false
        bossReward = 0
        pickups = level.pickups
        mines = level.mines
        revealedPickups = []
        trail = [position]
        accumulator = 0
        previousTimestamp = nil
        announcedCriticalHull = false
        announcedDockingHint = false
        dockingTooFast = false
        events.send(.runStarted(expeditionID))
        state = .playing
        journalOpen = true
        nextSnapshot = 5
        log("start", "Дело открыто: \(mission?.title ?? "Экспедиция за чёрным ящиком")")
        logWatch("mission.start", mission?.briefing ?? "Экспедиция за чёрным ящиком")
        if mission != nil { events.send(.diagnostic(.info, .event, "mission.start", missionMetadata)) }
        log("Экспедиция началась", phrase: "Капитан: погружаемся!")
        announce(mission.map { _ in objectiveText }
                 ?? A11yL10n.text("event.start", defaultValue: "Найди чёрный ящик. Сохрани заряд на возвращение."), duration: 7)
        updateCamera(dt: 1, snap: true)
        journal("start")
        navigate(to: "Game", reason: "start")
        journal("snapshot")
    }

    func returnToMenu() {
        guard recovery?.save(exiting: true) != false else { pause(); return }
        navigate(to: "Welcome", reason: "surface")
        if recovery == nil { outcome = .abandoned }
        if state == .playing || state == .paused { endJournal(result: recovery == nil ? "abandoned" : "suspended", reason: "surface") }
        closeJournal(recovery == nil ? "Экспедиция прервана: возвращение в меню" : "Экспедиция сохранена: возвращение в меню")
        log("Возвращение в меню")
        journalLeak = nil
        steering = .zero
        velocity = .zero
        accessibilityMoveRemaining = 0
        state = .ready
        previousTimestamp = nil
        accumulator = 0
    }

#if DEBUG
    /// Deterministic, non-production states used only by accessibility audits.
    func prepareAccessibilityAuditState(_ requestedState: String) {
        if isCampaign {
            if requestedState == "campaignClean" {
                campaignProgress = CampaignProgress()
                _ = selectMission(.aster)
            } else if requestedState == "station" || requestedState == "search" {
                campaignProgress.completed = requestedState == "station" ? [.aster] : [.aster, .currentStation]
                _ = selectMission(requestedState == "station" ? .currentStation : .silentSignal)
            } else if requestedState != "ready" {
                _ = selectMission(.aster)
            }
        }
        switch requestedState {
        case "readyClean": recovery?.deleteSave()
        case "station", "search": startGame(); pause()
        case "returned":
            startGame()
            samples = 1
            missionRun?.returningEarly = true
            position = level.base
            finish(success: true)
        case "playing": startGame()
        case "paused", "map": startGame(); pause()
        case "journal":
            startGame()
            setSteering(CGVector(dx: 1, dy: 0))
            for _ in 0..<60 { step(deltaTime: 0.1) }
            activateSonar()
            for _ in 0..<60 { step(deltaTime: 0.1) }
            hasBlackBox = true
            journal("blackBox")
            finish(success: true)
        case "completed":
            startGame()
            hasBlackBox = true
            samples = 2
            finish(success: true)
        case "gameOver":
            startGame()
            finish(success: false, reason: .energy)
        default: break
        }
    }
#endif

    func setSteering(_ vector: CGVector) {
        guard vector.dx.isFinite, vector.dy.isFinite else { journal("error", ["message": "nonfinite steering"]); log("input.invalid", "Некорректная команда руля", severity: "error"); return }
        guard state == .playing else { return }
        let wasSteering = hypot(steering.dx, steering.dy) > 0
        let wasMoving = inputStrength > 0
        accessibilityMoveRemaining = 0
        if runElapsed - lastSteeringTime >= 0.25 || vector == .zero {
            lastSteeringTime = runElapsed
            journal("steering", ["dx": String(Double(vector.dx)), "dy": String(Double(vector.dy))])
        }
        let length = hypot(vector.dx, vector.dy)
        if length < 0.08 { steering = .zero }
        else { steering = CGVector(dx: vector.dx / max(1, length), dy: vector.dy / max(1, length)) }
        let isSteering = hypot(steering.dx, steering.dy) > 0
        if wasSteering != isSteering { events.send(.diagnostic(.info, .control, "steering", ["active": String(isSteering)])) }
        if wasMoving != (inputStrength > 0) {
            log("steering", inputStrength > 0 ? "Включена тяга" : "Руль отпущен: торможение")
        }
        objectWillChange.send()
    }

    /// A VoiceOver button press becomes a short burst of the regular steering
    /// input, so movement still uses acceleration, currents, energy and collisions.
    func moveForVoiceOver(_ vector: CGVector) {
        guard state == .playing, vector.dx.isFinite, vector.dy.isFinite else { return }
        setSteering(vector)
        guard inputStrength > 0 else { return }
        accessibilityMoveRemaining = 0.35
    }

    func activateBoost() {
        guard canBoost else { logWatch("rejected.boost", "Форсаж недоступен"); log("ability.rejected", "Форсаж недоступен: заряд или перезарядка", severity: "warning"); journal("error", ["message": "boost unavailable"]); events.send(.diagnostic(.warning, .control, "ability.denied", ["ability": "Boost", "reason": state != .playing ? "state" : boostCooldown > 0 ? "cooldown" : "energy"])); return }
        defer { journal("boost") }
        logWatch("boost", "Включён форсаж")
        let length = inputStrength
        boostDirection = length > 0.08
            ? CGVector(dx: steering.dx / length, dy: steering.dy / length)
            : CGVector(dx: facing, dy: 0)
        energy -= Self.boostCost
        log("boost", "Форсаж — батарейку списали: −7 энергии")
        checkEnergyWarning()
        boostRemaining = 1.1
        boostCooldown = 4.5
        log("Форсаж включён", phrase: "Механик: полный вперёд!")
        if energy <= 0 { finish(success: false, reason: .energy) }
        objectWillChange.send()
    }

    func activateSonar() {
        guard canSonar else { logWatch("rejected.sonar", "Сонар перезаряжается"); log("ability.rejected", "Сонар недоступен", severity: "warning"); journal("error", ["message": "sonar unavailable"]); events.send(.diagnostic(.warning, .control, "ability.denied", ["ability": "Sonar", "reason": state != .playing ? "state" : sonarCooldown > 0 ? "cooldown" : "energy"])); return }
        defer { journal("sonar") }
        sonarRemaining = 5
        sonarCooldown = 8
        log("sonar", "Сонар: поиск находок")
        revealNearby(radius: 680)
        let scannedSignal = scanMissionSignal()
        if scannedSignal {
            // The identified contact is announced by the mission transition.
        } else if let portal, hypot(position.x - portal.position.x, position.y - portal.position.y) < 680 {
            portalRevealed = true
            announce(A11yL10n.text("event.portal.revealed", defaultValue: "Сонар обнаружил портал в пещеру"), duration: 3.5)
        } else {
        announce(A11yL10n.text("event.sonar", defaultValue: "Сонар: находки отмечены на карте"), duration: 2.5)
        }
        objectWillChange.send()
    }

    func activateLightBoost() {
        guard canLightBoost else { logWatch("rejected.light", "Усилитель фар недоступен"); log("ability.rejected", "Усилитель фар недоступен", severity: "warning"); journal("error", ["message": "lightBoost unavailable"]); events.send(.diagnostic(.warning, .control, "ability.denied", ["ability": "LightBoost", "reason": state != .playing ? "state" : lightBoostCooldown > 0 ? "cooldown" : "energy"])); return }
        defer { journal("lightBoost") }
        energy -= Self.lightBoostCost
        log("light", "Усилены фары: −5 энергии")
        checkEnergyWarning()
        lightBoostRemaining = Self.lightBoostDuration
        lightBoostCooldown = Self.lightBoostRecharge
        announce(A11yL10n.text("event.light.boost", defaultValue: "Фары усилены на 4 секунды"), duration: 2.5)
        if energy <= 0 { finish(success: false, reason: .energy) }
        objectWillChange.send()
    }

    func reportSurroundings() {
        announce(surroundingsDescription, duration: 7)
        objectWillChange.send()
    }

    var surroundingsDescription: String {
        sectorOverview
    }

    func pause() { pauseForScreen("Pause") }

    func pauseForScreen(_ screen: String) {
        guard state == .playing else { return }
        restoredPause = false
        pausedSnapshot = snapshot()
        recovery?.save(exiting: false)
        steering = .zero
        accessibilityMoveRemaining = 0
        state = .paused
        journal("pause")
        navigate(to: screen, reason: screen == "Map" ? "openMap" : "pause")
        receiptJournal.flush()
        log("Экспедиция приостановлена", level: .state)
        accumulator = 0
        previousTimestamp = nil
    }

    func togglePause() {
        if state == .paused {
            recovery?.cancelReminders()
            pausedSnapshot = nil
            if !restoredPause { accumulator = 0 }
            restoredPause = false
            previousTimestamp = nil
            state = .playing
            journal("resume")
            navigate(to: "Game", reason: "resume")
            log("Экспедиция продолжена", level: .state)
        } else { pause() }
    }

    func startLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(engine: self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        pause()
    }

    func step(deltaTime raw: TimeInterval) {
        guard raw.isFinite, raw > 0 else {
            log("simulation.invalidDelta", "Некорректный шаг симуляции", severity: "error")
            return
        }
        guard state == .playing || state == .ready else { return }
        let dt = min(raw, 0.1)
        if state == .playing {
            accumulator += dt
            while accumulator + 1e-10 >= Self.fixedStep && state == .playing {
                simulate(Self.fixedStep)
                accumulator = max(0, accumulator - Self.fixedStep)
            }
        }
        if journalOpen && runElapsed >= nextSnapshot {
            log("snapshot", "Показания приборов")
            nextSnapshot = runElapsed + 5
        }
        elapsed += dt
        if state == .playing, runElapsed - lastSnapshotTime >= 1 {
            lastSnapshotTime = runElapsed
            journal("snapshot")
        }
    }

    func current(at point: CGPoint) -> CGVector {
        var result = CGVector.zero
        for zone in level.currents where zone.bounds.contains(point) {
            let edge = min(point.x - zone.bounds.minX, zone.bounds.maxX - point.x,
                           point.y - zone.bounds.minY, zone.bounds.maxY - point.y)
            let strength = min(1, max(0, edge / 38))
            result.dx += zone.velocity.dx * strength
            result.dy += zone.velocity.dy * strength
        }
        return result
    }

    func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - camera.x + viewport.width / 2, y: point.y - camera.y + viewport.height / 2)
    }

    private func simulate(_ delta: TimeInterval) {
        let dt = CGFloat(delta)
        runElapsed += delta
        if let leak = journalLeak, runElapsed - leak.startedAt >= 3.5 { journalLeak = nil }
        if runElapsed >= nextSnapshotAt {
            nextSnapshotAt = runElapsed + 15
            log("Плановый доклад экипажа", level: .state,
                phrase: energy <= 25 ? "Механик: бережём заряд!" : "Штурман: глубина \(depth) м")
        }
        boostCooldown = max(0, boostCooldown - delta)
        lightBoostCooldown = max(0, lightBoostCooldown - delta)
        lightBoostRemaining = max(0, lightBoostRemaining - delta)
        sonarCooldown = max(0, sonarCooldown - delta)
        sonarRemaining = max(0, sonarRemaining - delta)
        invulnerability = max(0, invulnerability - delta)
        noticeRemaining = max(0, noticeRemaining - delta)
        let boosted = boostRemaining > 0
        let flow = zone == .ocean ? current(at: position) : .zero
        let drive = boosted ? CGVector(dx: boostDirection.dx * 220, dy: boostDirection.dy * 220)
            : CGVector(dx: steering.dx * Self.cruiseSpeed, dy: steering.dy * Self.cruiseSpeed)
        let targetVelocity = CGVector(dx: drive.dx + flow.dx, dy: drive.dy + flow.dy)
        let response: CGFloat = boosted ? 0.10 : (inputStrength > 0 ? 0.12 : 0.11)
        let decay = exp(-dt / response)
        let previous = position
        position.x += targetVelocity.dx * dt + (velocity.dx - targetVelocity.dx) * response * (1 - decay)
        position.y += targetVelocity.dy * dt + (velocity.dy - targetVelocity.dy) * response * (1 - decay)
        velocity.dx = targetVelocity.dx + (velocity.dx - targetVelocity.dx) * decay
        velocity.dy = targetVelocity.dy + (velocity.dy - targetVelocity.dy) * decay
        boostRemaining = max(0, boostRemaining - delta)
        if abs(drive.dx) > 12 { facing = drive.dx < 0 ? -1 : 1 }
        let thrustCost: CGFloat = boosted ? 1.8 : inputStrength * 1.15
        energy = max(0, energy - thrustCost * dt)
        if accessibilityMoveRemaining > 0 {
            accessibilityMoveRemaining = max(0, accessibilityMoveRemaining - delta)
            if accessibilityMoveRemaining == 0 { steering = .zero }
        }

        checkEnergyWarning()
        if zone == .ocean { resolveRocks() }
        guard state == .playing else { return }
        constrainToOcean()
        distance += hypot(position.x - previous.x, position.y - previous.y)
        if zone == .ocean {
            updateMines(delta)
            guard state == .playing else { return }
            collectNearby()
            updateMission()
            updatePortal()
        } else {
            updateBoss(delta)
        }
        guard state == .playing else { return }
        if energy <= 0 { finish(success: false, reason: .energy); return }
        if zone == .ocean, returningToBase, hypot(position.x - level.base.x, position.y - level.base.y) < 68, speed < 48 {
            finish(success: true)
        }
        if zone == .ocean, let last = trail.last, hypot(last.x - position.x, last.y - position.y) > 35 {
            trail.append(position)
            if trail.count > 600 { trail.removeFirst() }
        }
        if zone == .ocean {
            revealNearby(radius: sonarRemaining > 0 ? 680 : 240)
            if let portal, hypot(position.x - portal.position.x, position.y - portal.position.y) < 260 {
                portalRevealed = true
            }
        }
        announceThresholdsAndDocking()
        updateCamera(dt: dt)
        summaryTicks += 1
        if state == .playing && summaryTicks % 1200 == 0 { logWatch("snapshot", "Плановая сверка приборов") }
        if state == .playing && summaryTicks % 30 == 0 { events.send(.situation(situationSummary)) }
    }

    private func checkEnergyWarning() {
        if energy <= 25 && !didWarnEnergy {
            didWarnEnergy = true
            log("energy.low", "Осталось менее 25% энергии", severity: "warning")
            logWatch("energy.low", "Критический заряд батареи")
            events.send(.energyLow)
            log("Низкий заряд: пора возвращаться", level: .warning, phrase: "Механик: бережём заряд!")
        }
    }

    var situationSummary: SituationSummary {
        func contact(_ id: String, _ name: String, _ point: CGPoint) -> SituationSummary.Contact {
            let delta = CGVector(dx: point.x - position.x, dy: point.y - position.y)
            return .init(id: id, name: name, distance: Int(hypot(delta.dx, delta.dy) * 0.16), course: CompassCourse(vector: delta))
        }
        if zone == .bossCave {
            let strike = bossStrike.flatMap { strike in
                strike.phase == .warning ? contact("tentacle", A11yL10n.contactKind(.tentacle), strike.position) : nil
            }
            return SituationSummary(zone: String(describing: zone), position: position, energy: energy, hull: hull, targetName: targetLabel, depth: depth, speed: Int(speed * 0.16), returning: returningToBase,
                targetDistance: targetDistance, targetCourse: CompassCourse.n,
                danger: strike, find: nil, currentCourse: nil, currentSpeed: 0,
                caveTimeRemaining: Int(ceil(bossTimeRemaining)))
        }
        var dangers = mines.filter { $0.phase != .spent }.map {
            contact("mine:\($0.id)", A11yL10n.contactKind(.mine), $0.position)
        }
        for rock in level.rocks {
            dangers.append(contact("rock:\(rock.id)", A11yL10n.contactKind(.reef),
                                   AccessibilityNavigation.nearestPoint(on: rock, to: position)))
        }
        let finds = pickups.filter { !$0.collected && revealedPickups.contains($0.id) }.map {
            contact("pickup:\($0.id)", A11yL10n.pickupName($0.kind), $0.position)
        }
        let flow = current(at: position)
        return SituationSummary(zone: String(describing: zone), position: position, energy: energy, hull: hull, targetName: targetLabel, depth: depth, speed: Int(speed * 0.16), returning: returningToBase,
            targetDistance: targetDistance, targetCourse: CompassCourse(vector: CGVector(dx: target.x - position.x, dy: target.y - position.y)),
            danger: dangers.min { $0.distance < $1.distance }, find: finds.min { $0.distance < $1.distance },
            currentCourse: hypot(flow.dx, flow.dy) > 0.1 ? CompassCourse(vector: flow) : nil,
            currentSpeed: Int(hypot(flow.dx, flow.dy) * 0.16), caveTimeRemaining: nil)
    }

    private func resolveRocks() {
        for _ in 0..<3 {
            for rock in level.rocks {
                guard let hit = rock.contact(at: position, radius: Self.hullRadius) else { continue }
                position.x += hit.normal.dx * (hit.penetration + 0.05)
                position.y += hit.normal.dy * (hit.penetration + 0.05)
                let impact = velocity.dx * hit.normal.dx + velocity.dy * hit.normal.dy
                if impact < 0 {
                    velocity.dx -= hit.normal.dx * impact * 1.12
                    velocity.dy -= hit.normal.dy * impact * 1.12
                    if -impact > 78 { journal("collision", ["rock": String(rock.id)]); takeDamage(source: "reef"); boostRemaining = 0 }
                }
            }
        }
    }

    private func constrainToOcean() {
        let r = Self.hullRadius
        if position.x < r { position.x = r; velocity.dx = max(0, velocity.dx) }
        if position.x > worldSize.width - r { position.x = worldSize.width - r; velocity.dx = min(0, velocity.dx) }
        if position.y < 110 { position.y = 110; velocity.dy = max(0, velocity.dy) }
        if position.y > worldSize.height - 40 { position.y = worldSize.height - 40; velocity.dy = min(0, velocity.dy) }
    }

    private func updateMines(_ delta: TimeInterval) {
        for index in mines.indices {
            let distance = hypot(position.x - mines[index].position.x, position.y - mines[index].position.y)
            switch mines[index].phase {
            case .idle:
                if distance < OceanMine.triggerRadius {
                    journal("mine", ["id": String(mines[index].id), "phase": "armed"])
                    mines[index].phase = .armed
                    mines[index].timer = OceanMine.fuse
                    announce(A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!"), duration: 1.5, urgent: true)
                }
            case .armed:
                mines[index].timer -= delta
                if mines[index].timer <= 0 {
                    journal("mine", ["id": String(mines[index].id), "phase": "exploding"])
                    mines[index].phase = .exploding
                    mines[index].timer = 0.65
                    log("mine.explosion", "Взорвалась мина \(mines[index].id)", severity: "warning")
                    if distance < OceanMine.blastRadius + Self.hullRadius {
                        takeDamage(source: "mine")
                        let length = max(1, distance)
                        velocity.dx += (position.x - mines[index].position.x) / length * 110
                        velocity.dy += (position.y - mines[index].position.y) / length * 110
                        boostRemaining = 0
                    }
                }
            case .exploding:
                mines[index].timer -= delta
                if mines[index].timer <= 0 { mines[index].phase = .spent }
            case .spent: break
            }
        }
    }

    private func makePortal() -> OceanPortal? {
        guard randomValue() < Self.portalChance else { return nil }
        let candidates = level.portalCandidates.filter { candidate in
            let margin: CGFloat = 70
            guard candidate.x > margin, candidate.y > 130,
                  candidate.x < level.size.width - margin, candidate.y < level.size.height - margin,
                  level.rocks.allSatisfy({ $0.contact(at: candidate, radius: 54) == nil }),
                  level.mines.allSatisfy({ hypot($0.position.x - candidate.x, $0.position.y - candidate.y) > 145 })
            else { return false }
            return hypot(level.base.x - candidate.x, level.base.y - candidate.y) > 150
                && hypot(level.wreck.x - candidate.x, level.wreck.y - candidate.y) > 150
        }
        guard !candidates.isEmpty else { return nil }
        let roll = min(0.999_999, max(0, randomValue()))
        return OceanPortal(position: candidates[Int(roll * Double(candidates.count))])
    }

    private func updatePortal() {
        let oldZone = zone
        defer { if oldZone != zone { journal("zone") } }
        guard let portal,
              hypot(portal.position.x - position.x, portal.position.y - position.y) < 48 else { return }
        portalReturnPosition = position
        self.portal = nil
        zone = .bossCave
        accessibilityMoveRemaining = 0
        position = CGPoint(x: Self.caveSize.width / 2, y: Self.caveSize.height - 155)
        velocity = .zero
        steering = .zero
        boostRemaining = 0
        log("portal.enter", "Вход в пещеру спрута")
        bossTimeRemaining = Self.bossDuration
        bossStrikeCooldown = 1.6
        bossStrike = nil
        eventCount += 1
        announce(A11yL10n.text("event.portal.enter", defaultValue: "Портал! Пещера босса. Продержись 24 секунды под атаками гигантского спрута."), duration: 7, urgent: true)
        updateCamera(dt: 1, snap: true)
    }

    private func updateBoss(_ delta: TimeInterval) {
        bossTimeRemaining = max(0, bossTimeRemaining - delta)
        if bossTimeRemaining <= 0 {
            completeBossCave()
            return
        }
        if var strike = bossStrike {
            strike.timer -= delta
            if strike.timer <= 0 {
                switch strike.phase {
                case .warning:
                    strike.phase = .impact
                    strike.timer = 0.55
                    if hypot(strike.position.x - position.x, strike.position.y - position.y) < 112 + Self.hullRadius {
                        takeDamage(source: "tentacle")
                        velocity.dx += position.x < strike.position.x ? -125 : 125
                        velocity.dy += position.y < strike.position.y ? -95 : 95
                        boostRemaining = 0
                    } else {
                        announce(A11yL10n.text("event.tentacle.missed", defaultValue: "Щупальце промахнулось"), duration: 1.2)
                    }
                case .impact:
                    bossStrike = nil
                    return
                }
            }
            bossStrike = strike
        } else {
            bossStrikeCooldown -= delta
            if bossStrikeCooldown <= 0 {
                bossStrike = BossStrike(position: position, timer: 1.45)
                bossStrikeCooldown = 2.1
                eventCount += 1
                announce(A11yL10n.text("event.tentacle.warning", defaultValue: "Удар щупальца! Уходи в сторону или используй форсаж."), duration: 1.4, urgent: true)
            }
        }
    }

    private func completeBossCave() {
        defer { journal("bossCompleted") }
        bossDefeated = true
        bossReward = 300
        bossStrike = nil
        zone = .ocean
        position = portalReturnPosition
        accessibilityMoveRemaining = 0
        velocity = .zero
        steering = .zero
        log("boss.reward", "Спрут побеждён: артефакт +300")
        invulnerability = 1
        eventCount += 1
        announce(A11yL10n.text("event.boss.complete", defaultValue: "Спрут отступил! Артефакт пещеры добавил 300 к добыче."), duration: 6)
        updateCamera(dt: 1, snap: true)
    }

    private func takeDamage(source: String) {
        guard invulnerability <= 0, state == .playing else { return }
        invulnerability = 1.4
        damageCount += 1
        if hasShield {
            hasShield = false
            journal("damage", ["absorbed": "shield"])
            log("shield.hit", "Щит поглотил удар: \(source)", severity: "warning")
            announce(A11yL10n.text("event.shield.hit", defaultValue: "Щит поглотил удар"), duration: 2, urgent: true)
        } else {
            hull -= 1
            journal("damage")
            log("\(source).damage", source == "reef" ? "Обнял риф — корпус помят" : "Повреждение корпуса: \(source)", severity: "warning")
            announce(A11yL10n.format("event.hull.damage.format", defaultValue: "Корпус повреждён. %lld из 3", Int64(hull)),
                     duration: 2, urgent: true)
            if hull <= 0 { finish(success: false, reason: .hull) }
        }
    }

    private func collectNearby() {
        for index in pickups.indices where !pickups[index].collected {
            let pickup = pickups[index]
            guard hypot(pickup.position.x - position.x, pickup.position.y - position.y) < 39 else { continue }
            if pickup.kind == .battery && energy > 97 { continue }
            if pickup.kind == .shield && hasShield { continue }
            pickups[index].collected = true
            defer { journal(pickup.kind == .blackBox ? "blackBox" : "pickup", ["kind": pickup.kind.rawValue, "id": String(pickup.id)]) }
            pickupCount += 1
            switch pickup.kind {
            case .crystal:
                garage.crystals += 10
                saveGarage()
                announce(A11yL10n.format("event.crystals", defaultValue: "Кристаллы. Плюс 10. Баланс: %lld", Int64(crystals)))
            case .battery:
                energy = min(100, energy + 30)
                announce(A11yL10n.text("event.battery", defaultValue: "Батарея. Плюс 30 энергии"))
            case .shield:
                hasShield = true
                announce(A11yL10n.text("event.shield", defaultValue: "Щит. Защита от одного удара"))
            case .sample:
                samples += 1
                announce(A11yL10n.text("event.sample", defaultValue: "Образец на борту. Плюс 75 к добыче"))
            case .blackBox:
                hasBlackBox = true
                recovery?.record("blackBox", title: "Чёрный ящик найден", text: "Возвращайтесь на базу.")
                journal("target", ["newTarget": "base"])
                events.send(.objectiveChanged(true))
                announce(A11yL10n.text("event.blackbox", defaultValue: "Чёрный ящик найден. Вернись на базу!"), duration: 6)
            }
            log("pickup.\(pickup.kind.rawValue)", pickup.kind == .blackBox ? "Чёрный ящик — с собой" : "Подобрано: \(pickup.kind.rawValue), №\(pickup.id)")
        }
    }

    private func revealNearby(radius: CGFloat) {
        for pickup in pickups where hypot(position.x - pickup.position.x, position.y - pickup.position.y) < radius {
            revealedPickups.insert(pickup.id)
        }
    }

    private func distance(to point: CGPoint) -> CGFloat {
        hypot(point.x - position.x, point.y - position.y)
    }

    private func directionDescription(to point: CGPoint) -> String {
        let angle = atan2(point.y - position.y, point.x - position.x)
        let directions = ["справа", "справа снизу", "снизу", "слева снизу", "слева", "слева сверху", "сверху", "справа сверху"]
        let normalized = (angle + .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
        return directions[Int((normalized / (.pi / 4)).rounded()) % directions.count]
    }

    private func updateCamera(dt: CGFloat, snap: Bool = false) {
        let look = CGPoint(x: position.x + velocity.dx * 0.65,
                           y: position.y + velocity.dy * 0.45 + 15)
        // Keep the hull in the clear middle of the screen, away from the HUD and stick.
        let marginX = viewport.width / 2, marginY = viewport.height / 2
        let desired = CGPoint(x: min(max(look.x, marginX), max(marginX, worldSize.width - marginX)),
                              y: min(max(look.y, marginY), max(marginY, worldSize.height - marginY)))
        let amount: CGFloat = snap ? 1 : 1 - exp(-dt * 7)
        camera.x += (desired.x - camera.x) * amount
        camera.y += (desired.y - camera.y) * amount
    }

    func announceSectorOverview() {
        events.send(.speak(sectorOverview))
    }

    private func announceThresholdsAndDocking() {
        if hull == 1, !announcedCriticalHull {
            announcedCriticalHull = true
            announce(A11yL10n.text("event.hull.critical", defaultValue: "Внимание. Корпус: 1 из 3."), urgent: true)
        }
        let distanceToBase = hypot(position.x - level.base.x, position.y - level.base.y)
        let tooFast = zone == .ocean && returningToBase && distanceToBase < 68 && speed >= 48
        if tooFast && !dockingTooFast { events.send(.diagnostic(.warning, .control, "docking.denied", ["reason": "speed", "speed": String(Double(speed))])) }
        dockingTooFast = tooFast
        if zone == .ocean, state == .playing, returningToBase, distanceToBase < 180, !announcedDockingHint {
            announcedDockingHint = true
            announce(A11yL10n.text("event.docking", defaultValue: "База рядом. Остановись в круге базы для швартовки."))
        }
    }

    private func announce(_ text: String, duration: TimeInterval = 3, urgent: Bool = false) {
        log("notice", text, severity: urgent ? "warning" : "info")
        logWatch(urgent ? "danger" : "event", text)
        log(text, level: urgent ? .warning : .event,
            phrase: urgent ? "Экипаж: осторожно!" : "Борт: " + String(text.prefix(48)))
        events.send(urgent ? .danger(text) : .speak(text))
        notice = text
        noticeRemaining = duration
        accessibilityAnnouncementRevision += 1
    }

    func logWatch(_ event: String, _ message: String, reason: String = "") {
        let sobriety = CaptainLogger.Sobriety(rawValue: defaults.string(forKey: "podlodkaDive.captainSobriety") ?? "") ?? .sober
        captainLogger.record(event, message: message, expedition: expeditionID, sobriety: sobriety,
                             details: ["hull": String(hull), "energy": String(Int(energy)),
                                       "depth": String(depth), "cargo": String(cargoValue),
                                       "seconds": String(Int(runElapsed)), "zone": String(describing: zone),
                                       "missionID": mission?.rawValue ?? CampaignMission.aster.rawValue, "phase": missionPhase,
                                       "reason": reason])
    }

    private func directionAndDistance(to point: CGPoint) -> String {
        let dx = point.x - position.x, dy = point.y - position.y
        let angle = atan2(dy, dx)
        let octant = Int((angle / (.pi / 4)).rounded())
        let direction: String
        switch octant {
        case -3: direction = "слева сверху"
        case -2: direction = "сверху"
        case -1: direction = "справа сверху"
        case 0: direction = "справа"
        case 1: direction = "справа снизу"
        case 2: direction = "снизу"
        case 3: direction = "слева снизу"
        default: direction = "слева"
        }
        return "\(direction), \(Int(hypot(dx, dy) * 0.16)) метров"
    }

    private func finish(success: Bool, reason: FailureReason = .hull) {
        guard state == .playing else { return }
        let fullSuccess = success && objectiveReady
        outcome = success ? (fullSuccess ? .completed : .returned) : .gameOver
        let result = outcome!.rawValue
        recovery?.record(result, title: success ? "Экспедиция завершена" : "Экспедиция потеряна", text: "История сохранена. Продолжение недоступно.")
        recovery?.deleteSave()
        defer {
            if success { journal("docking") }
            journal(result)
            navigate(to: "Result", reason: result)
            endJournal(result: result, reason: success ? "docking" : String(describing: reason))
        }
        logWatch(result, success ? "Экспедиция вернулась на базу" : "Экспедиция потеряна",
                 reason: success ? "docked" : String(describing: reason))
        steering = .zero
        velocity = .zero
        accessibilityMoveRemaining = 0
        boostRemaining = 0
        lightBoostRemaining = 0
        if success {
            score = cargoValue
            events.send(.success(score))
            if fullSuccess {
                if let mission {
                    campaignProgress.complete(mission, score: score)
                    campaignProgress.save(to: defaults)
                }
                if score > bestScore {
                    events.send(.record(score))
                    bestScore = score
                    if mission == nil || mission == .aster { defaults.set(score, forKey: Self.bestKey) }
                }
            }
            state = .completed
            closeJournal(fullSuccess
                ? "Задание выполнено. \(mission?.title ?? "Чёрный ящик доставлен"). Добыча: \(score)"
                : "Добыча доставлена: \(score). Задание не выполнено.")
            log(fullSuccess ? "Экспедиция завершена. Доставлено: \(score)"
                : "Вернулись без выполнения задания. Доставлено: \(score)")
        } else {
            if reason == .energy { events.send(.danger(A11yL10n.text("event.energy.empty", defaultValue: "Энергия закончилась"))) }
            failureReason = reason
            score = 0
            state = .gameOver
            closeJournal(reason == .energy ? "Энергия закончилась. Добыча потеряна" : "Корпус разрушен. Добыча потеряна", severity: "error")
            log(reason == .energy ? "Энергия закончилась" : "Корпус разрушен", level: .error)
        }
    }

    fileprivate func frameDidFire(_ link: CADisplayLink) {
        defer { previousTimestamp = link.timestamp }
        guard let previousTimestamp else { return }
        step(deltaTime: link.timestamp - previousTimestamp)
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var engine: GameEngine?
    init(engine: GameEngine) { self.engine = engine }
    @objc func tick(_ link: CADisplayLink) { engine?.frameDidFire(link) }
}

struct ExpeditionSnapshot: Codable {
    var version = 1
    var id: UUID
    var level: OceanLevel
    var position: CGPoint
    var velocity: CGVector
    var steering: CGVector
    var camera: CGPoint
    var facing: CGFloat
    var energy: CGFloat
    var hull: Int
    var hasShield: Bool
    var hasBlackBox: Bool
    var samples: Int
    var score: Int
    var bestAtStart: Int
    var runElapsed: TimeInterval
    var distance: CGFloat
    var pickups: [OceanPickup]
    var mines: [OceanMine]
    var revealedPickups: Set<Int>
    var trail: [CGPoint]
    var notice: String
    var failureReason: FailureReason
    var zone: DiveZone
    var portal: OceanPortal?
    var portalRevealed: Bool
    var bossStrike: BossStrike?
    var bossDefeated: Bool
    var bossReward: Int
    var boostDirection: CGVector
    var portalReturnPosition: CGPoint
    var announcedCriticalHull: Bool
    var announcedDockingHint: Bool
    var dockingTooFast: Bool
    var didWarnEnergy: Bool
    var summaryTicks: Int
    var pickupCount: Int
    var damageCount: Int
    var eventCount: Int
    var elapsed: TimeInterval
    var expeditionNumber: Int
    var leakOnLeft: Bool
    var boostRemaining: TimeInterval
    var boostCooldown: TimeInterval
    var lightBoostRemaining: TimeInterval
    var lightBoostCooldown: TimeInterval
    var sonarRemaining: TimeInterval
    var sonarCooldown: TimeInterval
    var invulnerability: TimeInterval
    var noticeRemaining: TimeInterval
    var bossTimeRemaining: TimeInterval
    var accessibilityMoveRemaining: TimeInterval
    var bossStrikeCooldown: TimeInterval
    var accumulator: TimeInterval
    var nextLeakAt: TimeInterval
    var nextSnapshotAt: TimeInterval
    var nextSnapshot: TimeInterval
    var missionRun: MissionRun? = nil
}
