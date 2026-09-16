import Combine
import Foundation
import QuartzCore
import UIKit

enum RunState: Equatable { case ready, playing, paused, gameOver, completed }
enum FailureReason { case hull, energy }
enum PickupKind: String { case battery, shield, sample, blackBox, crystal }
enum MinePhase { case idle, armed, exploding, spent }
enum DiveZone: Equatable { case ocean, bossCave }
enum BossStrikePhase { case warning, impact }

struct OceanPortal {
    let position: CGPoint
}

struct BossStrike {
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
               contactKind(contact.kind), Int64(contact.distanceMeters), Int64(contact.clockHour))
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

struct OceanPickup: Identifiable {
    let id: Int
    let kind: PickupKind
    let position: CGPoint
    var collected = false
}

struct OceanMine: Identifiable {
    let id: Int
    let position: CGPoint
    var phase: MinePhase = .idle
    var timer: TimeInterval = 0
    static let triggerRadius: CGFloat = 120
    static let blastRadius: CGFloat = 96
    static let fuse: TimeInterval = 1.25
}

struct OceanCurrent: Identifiable {
    let id: Int
    let bounds: CGRect
    let velocity: CGVector
}

struct RockContact {
    let normal: CGVector
    let penetration: CGFloat
}

struct OceanRock: Identifiable {
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

struct OceanLevel {
    let size: CGSize
    let spawn: CGPoint
    let base: CGPoint
    let wreck: CGPoint
    var rocks: [OceanRock] = []
    var pickups: [OceanPickup] = []
    var mines: [OceanMine] = []
    var currents: [OceanCurrent] = []
    var portalCandidates: [CGPoint] = []

    static var expedition: OceanLevel {
        func rock(_ id: Int, _ points: [(CGFloat, CGFloat)]) -> OceanRock {
            OceanRock(id: id, vertices: points.map { CGPoint(x: $0.0, y: $0.1) })
        }
        func pickup(_ id: Int, _ kind: PickupKind, _ x: CGFloat, _ y: CGFloat) -> OceanPickup {
            OceanPickup(id: id, kind: kind, position: CGPoint(x: x, y: y))
        }
        return OceanLevel(
            size: CGSize(width: 1560, height: 2600), spawn: CGPoint(x: 245, y: 290),
            base: CGPoint(x: 190, y: 230), wreck: CGPoint(x: 1370, y: 2330),
            rocks: [
                rock(0, [(345, 480), (510, 445), (630, 535), (665, 730), (560, 920), (345, 875), (290, 690)]),
                rock(1, [(1080, 425), (1430, 480), (1480, 700), (1390, 960), (1060, 905), (985, 650)]),
                rock(2, [(700, 1140), (965, 1120), (1070, 1310), (1000, 1550), (770, 1620), (595, 1450), (610, 1260)]),
                rock(3, [(110, 1460), (245, 1410), (350, 1570), (320, 1880), (170, 1990), (75, 1810)]),
                rock(4, [(1010, 1860), (1160, 1820), (1260, 1970), (1200, 2130), (995, 2160), (895, 2030)]),
                rock(5, [(580, 2230), (720, 2200), (805, 2350), (725, 2520), (515, 2530), (470, 2380)])
            ],
            pickups: [
                pickup(0, .blackBox, 1370, 2330),
                pickup(1, .battery, 185, 1070), pickup(2, .battery, 440, 1780),
                pickup(3, .battery, 1480, 2470), pickup(4, .battery, 1450, 1240),
                pickup(5, .shield, 790, 470), pickup(6, .shield, 860, 2260),
                pickup(7, .sample, 390, 320), pickup(8, .sample, 740, 830),
                pickup(9, .sample, 1220, 1080), pickup(10, .sample, 465, 1370),
                pickup(11, .sample, 820, 1770), pickup(12, .sample, 1350, 1660),
                pickup(13, .sample, 190, 2250), pickup(14, .sample, 900, 2450),
                pickup(15, .crystal, 320, 320), pickup(16, .crystal, 740, 900),
                pickup(17, .crystal, 440, 1700), pickup(18, .crystal, 1350, 1740)
            ],
            mines: [
                OceanMine(id: 0, position: CGPoint(x: 820, y: 700)),
                OceanMine(id: 1, position: CGPoint(x: 875, y: 1030)),
                OceanMine(id: 2, position: CGPoint(x: 1190, y: 1390)),
                OceanMine(id: 3, position: CGPoint(x: 1370, y: 1950)),
                OceanMine(id: 4, position: CGPoint(x: 440, y: 2190)),
                OceanMine(id: 5, position: CGPoint(x: 1060, y: 2420))
            ],
            currents: [
                OceanCurrent(id: 0, bounds: CGRect(x: 725, y: 540, width: 205, height: 490), velocity: CGVector(dx: 0, dy: 48)),
                OceanCurrent(id: 1, bounds: CGRect(x: 520, y: 1645, width: 780, height: 155), velocity: CGVector(dx: 58, dy: 0)),
                OceanCurrent(id: 2, bounds: CGRect(x: 1290, y: 1460, width: 230, height: 750), velocity: CGVector(dx: 0, dy: -38))
            ],
            portalCandidates: [
                CGPoint(x: 850, y: 320), CGPoint(x: 410, y: 1120),
                CGPoint(x: 1330, y: 1740), CGPoint(x: 870, y: 2110)
            ])
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
    case speak(String)
    case danger(String)
    case energyLow
    case stateChanged(RunState)
    case objectiveChanged(Bool)
    case success(Int)
    case record(Int)
    case situation(SituationSummary)
}

@MainActor
final class GameEngine: NSObject, ObservableObject {
    private let journal: any ExpeditionLogging
    private(set) var diveID: UUID?
    private var journalOpen = false
    private var nextSnapshot: TimeInterval = 5

    private func log(_ kind: String, _ message: String, severity: String = "info") {
        guard journalOpen, let diveID else { return }
        journal.record(JournalEntry(id: UUID(), diveID: diveID, date: Date(), elapsed: runElapsed,
            kind: kind, severity: severity, message: message,
            boat: BoatSnapshot(x: Double(position.x), y: Double(position.y), energy: Double(energy),
                hull: hull, cargo: cargoValue, blackBox: hasBlackBox, shield: hasShield,
                zone: String(describing: zone), state: String(describing: state), speed: Double(speed))))
    }

    private func closeJournal(_ outcome: String, severity: String = "info") {
        log("finish", outcome, severity: severity)
        journalOpen = false
        journal.flush()
    }

    let events = PassthroughSubject<GameEvent, Never>()
    @Published private(set) var state: RunState = .ready {
        didSet {
            if oldValue != state {
                events.send(.stateChanged(state))
                log("state", "Режим: \(state)")
            }
        }
    }
    private var didWarnEnergy = false
    private var summaryTicks = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var bestScore: Int
    @Published private(set) var pickupCount = 0
    @Published private(set) var damageCount = 0
    @Published private(set) var accessibilityAnnouncementRevision = 0
    @Published private(set) var eventCount = 0

    @Published private var garage: GarageSave
    private static let garageKey = "podlodkaDive.garage.v1"
    var crystals: Int { garage.crystals }
    var selectedStyle: SubmarineStyle { garage.selected }

    let level: OceanLevel
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
    private static let bestKey = "podlodkaDive.expedition.bestSalvage"
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

    init(defaults: UserDefaults = .standard, level: OceanLevel = .expedition,
         journal: any ExpeditionLogging = ExpeditionJournal.shared,
         randomValue: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        var saved = defaults.data(forKey: Self.garageKey)
            .flatMap { try? JSONDecoder().decode(GarageSave.self, from: $0) } ?? GarageSave()
        saved.crystals = max(0, saved.crystals)
        saved.unlocked.insert(.classic)
        if !saved.unlocked.contains(saved.selected) { saved.selected = .classic }
        garage = saved
        self.journal = journal
        self.defaults = defaults
        self.level = level
        self.randomValue = randomValue
        position = level.spawn
        pickups = level.pickups
        mines = level.mines
        bestScore = defaults.integer(forKey: Self.bestKey)
        super.init()
        updateCamera(dt: 1, snap: true)
    }

    var speed: CGFloat { hypot(velocity.dx, velocity.dy) }
    var inputStrength: CGFloat { hypot(steering.dx, steering.dy) }
    var isThrustActive: Bool { state == .playing && (inputStrength > 0 || boostRemaining > 0) }
    var cargoValue: Int { samples * 75 + (hasBlackBox ? 600 : 0) + bossReward }
    var depth: Int { Int(max(0, position.y - 100) * 0.16) }
    var target: CGPoint { zone == .bossCave ? CGPoint(x: Self.caveSize.width / 2, y: 145) : (hasBlackBox ? level.base : level.wreck) }
    var targetDistance: Int { Int(hypot(target.x - position.x, target.y - position.y) * 0.16) }
    var isNewRecord: Bool { state == .completed && score > bestAtStart }
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
        var contacts = [contact(id: "target", kind: .target, point: target),
                        contact(id: "base", kind: .base, point: level.base)]
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
        let objective = hasBlackBox
            ? A11yL10n.text("a11y.objective.base", defaultValue: "Доставить чёрный ящик на базу")
            : A11yL10n.text("a11y.objective.blackbox", defaultValue: "Найти чёрный ящик")
        let nearby = sonarContacts.prefix(3).map(A11yL10n.contact).joined(separator: "; ")
        let remaining = pickups.filter { !$0.collected }.count
        return A11yL10n.format("a11y.map.overview.format",
                               defaultValue: "Обзор сектора. Цель: %@. Ближайшие контакты: %@. Осталось находок: %lld.",
                               objective, nearby, Int64(remaining))
    }
    var worldSize: CGSize { zone == .bossCave ? Self.caveSize : level.size }
    var objectiveText: String {
        if zone == .bossCave { return "Переживи нападение · \(Int(ceil(bossTimeRemaining))) с" }
        return hasBlackBox ? "Вернись на базу" : "Найди чёрный ящик"
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
        var parts = ["Цель \(directionAndDistance(to: target))."]
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

    func owns(_ style: SubmarineStyle) -> Bool { garage.unlocked.contains(style) }

    /// Purchases and equipment changes are allowed only before an expedition.
    @discardableResult
    func customize(_ style: SubmarineStyle) -> String {
        guard state == .ready else { return "Открой гараж перед началом экспедиции." }
        let purchased = !owns(style)
        if purchased {
            guard crystals >= style.price else { return "Не хватает кристаллов: нужно ещё \(style.price - crystals)." }
            garage.crystals -= style.price
            garage.unlocked.insert(style)
        }
        garage.selected = style
        saveGarage()
        return "\(purchased ? "Куплено и установлено" : "Установлено"): \(style.title). Баланс: \(crystals) кристаллов."
    }

    private func saveGarage() {
        if let data = try? JSONEncoder().encode(garage) { defaults.set(data, forKey: Self.garageKey) }
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

    func startGame() {
        closeJournal("Экспедиция прервана: начато новое погружение")
        didWarnEnergy = false
        summaryTicks = 0
        zone = .ocean
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
        diveID = UUID()
        state = .playing
        journalOpen = true
        nextSnapshot = 5
        log("start", "Дело открыто: экспедиция за чёрным ящиком")
        announce(A11yL10n.text("event.start", defaultValue: "Найди чёрный ящик. Сохрани заряд на возвращение."), duration: 7)
        updateCamera(dt: 1, snap: true)
    }

    func returnToMenu() {
        closeJournal("Экспедиция прервана: возвращение в меню")
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
        switch requestedState {
        case "playing": startGame()
        case "paused", "map": startGame(); pause()
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
        guard state == .playing else { return }
        guard vector.dx.isFinite, vector.dy.isFinite else {
            log("input.invalid", "Некорректная команда руля", severity: "error")
            return
        }
        let wasMoving = inputStrength > 0
        accessibilityMoveRemaining = 0
        let length = hypot(vector.dx, vector.dy)
        if length < 0.08 { steering = .zero }
        else { steering = CGVector(dx: vector.dx / max(1, length), dy: vector.dy / max(1, length)) }
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
        guard canBoost else { log("ability.rejected", "Форсаж недоступен: заряд или перезарядка", severity: "warning"); return }
        let length = inputStrength
        boostDirection = length > 0.08
            ? CGVector(dx: steering.dx / length, dy: steering.dy / length)
            : CGVector(dx: facing, dy: 0)
        energy -= Self.boostCost
        log("boost", "Форсаж — батарейку списали: −7 энергии")
        checkEnergyWarning()
        boostRemaining = 1.1
        boostCooldown = 4.5
        if energy <= 0 { finish(success: false, reason: .energy) }
        objectWillChange.send()
    }

    func activateSonar() {
        guard canSonar else { log("ability.rejected", "Сонар недоступен", severity: "warning"); return }
        sonarRemaining = 5
        sonarCooldown = 8
        log("sonar", "Сонар: поиск находок")
        revealNearby(radius: 680)
        if let portal, hypot(position.x - portal.position.x, position.y - portal.position.y) < 680 {
            portalRevealed = true
            announce(A11yL10n.text("event.portal.revealed", defaultValue: "Сонар обнаружил портал в пещеру"), duration: 3.5)
        } else {
        announce(A11yL10n.text("event.sonar", defaultValue: "Сонар: находки отмечены на карте"), duration: 2.5)
        }
        objectWillChange.send()
    }

    func activateLightBoost() {
        guard canLightBoost else { log("ability.rejected", "Усилитель фар недоступен", severity: "warning"); return }
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

    func pause() {
        guard state == .playing else { return }
        steering = .zero
        accessibilityMoveRemaining = 0
        state = .paused
        journal.flush()
        accumulator = 0
        previousTimestamp = nil
    }

    func togglePause() {
        if state == .paused {
            steering = .zero
            accessibilityMoveRemaining = 0
            accumulator = 0
            previousTimestamp = nil
            state = .playing
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
            updatePortal()
        } else {
            updateBoss(delta)
        }
        guard state == .playing else { return }
        if energy <= 0 { finish(success: false, reason: .energy); return }
        if zone == .ocean, hasBlackBox, hypot(position.x - level.base.x, position.y - level.base.y) < 68, speed < 48 {
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
        if state == .playing && summaryTicks % 30 == 0 { events.send(.situation(situationSummary)) }
    }

    private func checkEnergyWarning() {
        if energy <= 25 && !didWarnEnergy {
            didWarnEnergy = true
            log("energy.low", "Осталось менее 25% энергии", severity: "warning")
            events.send(.energyLow)
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
            return SituationSummary(depth: depth, speed: Int(speed * 0.16), returning: hasBlackBox,
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
        return SituationSummary(depth: depth, speed: Int(speed * 0.16), returning: hasBlackBox,
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
                    if -impact > 78 { takeDamage(source: "reef"); boostRemaining = 0 }
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
                    mines[index].phase = .armed
                    mines[index].timer = OceanMine.fuse
                    announce(A11yL10n.text("event.mine", defaultValue: "Мина активирована — отойди!"), duration: 1.5, urgent: true)
                }
            case .armed:
                mines[index].timer -= delta
                if mines[index].timer <= 0 {
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
            log("shield.hit", "Щит поглотил удар: \(source)", severity: "warning")
            announce(A11yL10n.text("event.shield.hit", defaultValue: "Щит поглотил удар"), duration: 2, urgent: true)
        } else {
            hull -= 1
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
        if zone == .ocean, state == .playing, hasBlackBox, distanceToBase < 180, !announcedDockingHint {
            announcedDockingHint = true
            announce(A11yL10n.text("event.docking", defaultValue: "База рядом. Остановись в круге базы для швартовки."))
        }
    }

    private func announce(_ text: String, duration: TimeInterval = 3, urgent: Bool = false) {
        log("notice", text, severity: urgent ? "warning" : "info")
        events.send(urgent ? .danger(text) : .speak(text))
        notice = text
        noticeRemaining = duration
        accessibilityAnnouncementRevision += 1
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
        steering = .zero
        velocity = .zero
        accessibilityMoveRemaining = 0
        boostRemaining = 0
        lightBoostRemaining = 0
        if success {
            score = cargoValue
            events.send(.success(score))
            if score > bestScore {
                events.send(.record(score))
                bestScore = score
                defaults.set(score, forKey: Self.bestKey)
            }
            state = .completed
            closeJournal("Чёрный ящик доставлен. Добыча: \(score)")
        } else {
            if reason == .energy { events.send(.danger(A11yL10n.text("event.energy.empty", defaultValue: "Энергия закончилась"))) }
            failureReason = reason
            score = 0
            state = .gameOver
            closeJournal(reason == .energy ? "Энергия закончилась. Добыча потеряна" : "Корпус разрушен. Добыча потеряна", severity: "error")
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
