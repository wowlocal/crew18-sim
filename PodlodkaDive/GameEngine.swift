import Combine
import Foundation
import QuartzCore

enum RunState: Equatable { case ready, playing, paused, gameOver, completed }
enum FailureReason { case hull, energy }
enum PickupKind: String { case battery, shield, sample, blackBox }
enum MinePhase { case idle, armed, exploding, spent }

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
                pickup(13, .sample, 190, 2250), pickup(14, .sample, 900, 2450)
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
            ])
    }
}

@MainActor
final class GameEngine: NSObject, ObservableObject {
    @Published private(set) var state: RunState = .ready
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var bestScore: Int
    @Published private(set) var pickupCount = 0
    @Published private(set) var damageCount = 0

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

    private var boostDirection = CGVector(dx: 1, dy: 0)
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var accumulator: TimeInterval = 0
    private let defaults: UserDefaults
    private static let bestKey = "podlodkaDive.expedition.bestSalvage"
    static let hullRadius: CGFloat = 20
    static let cruiseSpeed: CGFloat = 96
    static let boostCost: CGFloat = 7
    private static let fixedStep: TimeInterval = 1.0 / 120.0

    init(defaults: UserDefaults = .standard, level: OceanLevel = .expedition) {
        self.defaults = defaults
        self.level = level
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
    var cargoValue: Int { samples * 75 + (hasBlackBox ? 600 : 0) }
    var depth: Int { Int(max(0, position.y - 100) * 0.16) }
    var target: CGPoint { hasBlackBox ? level.base : level.wreck }
    var targetDistance: Int { Int(hypot(target.x - position.x, target.y - position.y) * 0.16) }
    var isNewRecord: Bool { state == .completed && score > bestAtStart }
    var canBoost: Bool { state == .playing && boostCooldown <= 0 && energy >= Self.boostCost }
    var canSonar: Bool { state == .playing && sonarCooldown <= 0 }
    var submarineRotationRadians: Double { Double(atan2(velocity.dy, max(55, abs(velocity.dx)))) * 0.55 }

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
        sonarRemaining = 0
        sonarCooldown = 0
        invulnerability = 0
        pickups = level.pickups
        mines = level.mines
        revealedPickups = []
        trail = [position]
        accumulator = 0
        previousTimestamp = nil
        announce("Найди чёрный ящик. Сохрани заряд на возвращение.", duration: 7)
        updateCamera(dt: 1, snap: true)
        state = .playing
    }

    func returnToMenu() {
        steering = .zero
        velocity = .zero
        state = .ready
        previousTimestamp = nil
        accumulator = 0
    }

    func setSteering(_ vector: CGVector) {
        guard state == .playing, vector.dx.isFinite, vector.dy.isFinite else { return }
        let length = hypot(vector.dx, vector.dy)
        if length < 0.08 { steering = .zero }
        else { steering = CGVector(dx: vector.dx / max(1, length), dy: vector.dy / max(1, length)) }
        objectWillChange.send()
    }

    func activateBoost() {
        guard canBoost else { return }
        let length = inputStrength
        boostDirection = length > 0.08
            ? CGVector(dx: steering.dx / length, dy: steering.dy / length)
            : CGVector(dx: facing, dy: 0)
        energy -= Self.boostCost
        boostRemaining = 1.1
        boostCooldown = 4.5
        if energy <= 0 { finish(success: false, reason: .energy) }
        objectWillChange.send()
    }

    func activateSonar() {
        guard canSonar else { return }
        sonarRemaining = 5
        sonarCooldown = 8
        revealNearby(radius: 680)
        announce("Сонар: находки отмечены на карте", duration: 2.5)
        objectWillChange.send()
    }

    func pause() {
        guard state == .playing else { return }
        steering = .zero
        state = .paused
        accumulator = 0
        previousTimestamp = nil
    }

    func togglePause() {
        if state == .paused {
            steering = .zero
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
        guard raw.isFinite, raw > 0, state == .playing || state == .ready else { return }
        let dt = min(raw, 0.1)
        if state == .playing {
            accumulator += dt
            while accumulator + 1e-10 >= Self.fixedStep && state == .playing {
                simulate(Self.fixedStep)
                accumulator = max(0, accumulator - Self.fixedStep)
            }
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
        sonarCooldown = max(0, sonarCooldown - delta)
        sonarRemaining = max(0, sonarRemaining - delta)
        invulnerability = max(0, invulnerability - delta)
        noticeRemaining = max(0, noticeRemaining - delta)
        let boosted = boostRemaining > 0
        let flow = current(at: position)
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

        resolveRocks()
        guard state == .playing else { return }
        constrainToOcean()
        distance += hypot(position.x - previous.x, position.y - previous.y)
        updateMines(delta)
        guard state == .playing else { return }
        collectNearby()
        if energy <= 0 { finish(success: false, reason: .energy); return }
        if hasBlackBox, hypot(position.x - level.base.x, position.y - level.base.y) < 68, speed < 48 {
            finish(success: true)
        }
        if let last = trail.last, hypot(last.x - position.x, last.y - position.y) > 35 {
            trail.append(position)
            if trail.count > 600 { trail.removeFirst() }
        }
        revealNearby(radius: sonarRemaining > 0 ? 680 : 240)
        updateCamera(dt: dt)
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
                    if -impact > 78 { takeDamage(); boostRemaining = 0 }
                }
            }
        }
    }

    private func constrainToOcean() {
        let r = Self.hullRadius
        if position.x < r { position.x = r; velocity.dx = max(0, velocity.dx) }
        if position.x > level.size.width - r { position.x = level.size.width - r; velocity.dx = min(0, velocity.dx) }
        if position.y < 110 { position.y = 110; velocity.dy = max(0, velocity.dy) }
        if position.y > level.size.height - 40 { position.y = level.size.height - 40; velocity.dy = min(0, velocity.dy) }
    }

    private func updateMines(_ delta: TimeInterval) {
        for index in mines.indices {
            let distance = hypot(position.x - mines[index].position.x, position.y - mines[index].position.y)
            switch mines[index].phase {
            case .idle:
                if distance < OceanMine.triggerRadius {
                    mines[index].phase = .armed
                    mines[index].timer = OceanMine.fuse
                    announce("Мина активирована — отойди!", duration: 1.5)
                }
            case .armed:
                mines[index].timer -= delta
                if mines[index].timer <= 0 {
                    mines[index].phase = .exploding
                    mines[index].timer = 0.65
                    if distance < OceanMine.blastRadius + Self.hullRadius {
                        takeDamage()
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

    private func takeDamage() {
        guard invulnerability <= 0, state == .playing else { return }
        invulnerability = 1.4
        damageCount += 1
        if hasShield {
            hasShield = false
            announce("Щит поглотил удар", duration: 2)
        } else {
            hull -= 1
            announce("Корпус повреждён · \(hull)/3", duration: 2)
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
            case .battery:
                energy = min(100, energy + 30)
                announce("Батарея · +30 энергии")
            case .shield:
                hasShield = true
                announce("Щит · защита от одного удара")
            case .sample:
                samples += 1
                announce("Образец на борту · +75 к добыче")
            case .blackBox:
                hasBlackBox = true
                announce("Чёрный ящик найден. Вернись на базу!", duration: 6)
            }
        }
    }

    private func revealNearby(radius: CGFloat) {
        for pickup in pickups where hypot(position.x - pickup.position.x, position.y - pickup.position.y) < radius {
            revealedPickups.insert(pickup.id)
        }
    }

    private func updateCamera(dt: CGFloat, snap: Bool = false) {
        let look = CGPoint(x: position.x + velocity.dx * 0.65,
                           y: position.y + velocity.dy * 0.45 + 15)
        // Keep the hull in the clear middle of the screen, away from the HUD and stick.
        let marginX = viewport.width / 2, marginY = viewport.height / 2
        let desired = CGPoint(x: min(max(look.x, marginX), max(marginX, level.size.width - marginX)),
                              y: min(max(look.y, marginY), max(marginY, level.size.height - marginY)))
        let amount: CGFloat = snap ? 1 : 1 - exp(-dt * 7)
        camera.x += (desired.x - camera.x) * amount
        camera.y += (desired.y - camera.y) * amount
    }

    private func announce(_ text: String, duration: TimeInterval = 3) {
        notice = text
        noticeRemaining = duration
    }

    private func finish(success: Bool, reason: FailureReason = .hull) {
        steering = .zero
        velocity = .zero
        boostRemaining = 0
        if success {
            score = cargoValue
            if score > bestScore {
                bestScore = score
                defaults.set(score, forKey: Self.bestKey)
            }
            state = .completed
        } else {
            failureReason = reason
            score = 0
            state = .gameOver
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
