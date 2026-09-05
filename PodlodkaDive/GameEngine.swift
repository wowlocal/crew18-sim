import Combine
import Foundation
import QuartzCore

enum RunState: Equatable {
    case ready
    case playing
    case paused
    case gameOver
}

struct ReefGate: Identifiable, Equatable {
    let id: Int
    var x: CGFloat
    let gapCenterY: CGFloat
    let gapHeight: CGFloat
    var hasScored: Bool
    let seed: UInt64

    var topEdge: CGFloat { gapCenterY - gapHeight / 2 }
    var bottomEdge: CGFloat { gapCenterY + gapHeight / 2 }
}

@MainActor
final class GameEngine: NSObject, ObservableObject {
    @Published private(set) var state: RunState = .ready
    @Published private(set) var score = 0
    @Published private(set) var bestScore: Int
    @Published private(set) var submarineY: CGFloat = 360
    @Published private(set) var submarineVelocity: CGFloat = 0
    @Published private(set) var reefs: [ReefGate] = []
    @Published private(set) var elapsed: TimeInterval = 0

    private(set) var worldSize: CGSize = .zero
    private var isThrusting = false
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var nextGateID = 0
    private var randomState: UInt64 = 0xD1CE_CAFE_18
    private var runElapsed: TimeInterval = 0

    private let defaults: UserDefaults
    private static let bestScoreKey = "podlodkaDive.bestScore"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bestScore = defaults.integer(forKey: Self.bestScoreKey)
        super.init()
    }

    var submarineX: CGFloat {
        max(92, worldSize.width * 0.27)
    }

    var submarineRotationRadians: Double {
        Double(max(-0.32, min(0.32, submarineVelocity / 430)))
    }

    var speed: CGFloat {
        154 + CGFloat(min(score * 4, 76))
    }

    var isThrustActive: Bool {
        state == .playing && isThrusting
    }

    func startLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameDidFire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 40, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let wasEmpty = worldSize == .zero
        worldSize = size
        if wasEmpty || state == .ready {
            submarineY = size.height * 0.22
        } else {
            submarineY = min(max(submarineY, 48), size.height - 48)
        }
    }

    func startGame() {
        guard worldSize.width > 0, worldSize.height > 0 else { return }
        state = .playing
        score = 0
        runElapsed = 0
        submarineY = worldSize.height * 0.48
        submarineVelocity = 0
        reefs.removeAll(keepingCapacity: true)
        isThrusting = false
        spawnGate(at: worldSize.width + 125)
    }

    func setThrusting(_ active: Bool) {
        if state == .ready || state == .gameOver {
            if active {
                startGame()
                isThrusting = true
            }
            return
        }
        guard state == .playing else { return }
        isThrusting = active
    }

    func togglePause() {
        switch state {
        case .playing:
            state = .paused
            isThrusting = false
        case .paused:
            state = .playing
        default:
            break
        }
    }

    func step(deltaTime rawDeltaTime: TimeInterval) {
        guard state == .playing, worldSize.width > 0, worldSize.height > 0 else { return }

        let deltaTime = min(max(rawDeltaTime, 0), 1.0 / 20.0)
        let dt = CGFloat(deltaTime)
        runElapsed += deltaTime

        // Water is much more viscous than air. The boat slowly sinks, thrust pushes
        // it upward, and a gentle current prevents the movement feeling mechanical.
        let current = sin(CGFloat(runElapsed) * 1.7) * 24
        let downwardBallast: CGFloat = 105
        let upwardThrust: CGFloat = isThrusting ? -345 : 0
        submarineVelocity += (downwardBallast + upwardThrust + current) * dt
        submarineVelocity *= exp(-1.35 * dt)
        submarineVelocity = max(-185, min(175, submarineVelocity))
        submarineY += submarineVelocity * dt

        for index in reefs.indices {
            reefs[index].x -= speed * dt
            if !reefs[index].hasScored,
               reefs[index].x + 37 < submarineX {
                reefs[index].hasScored = true
                score += 1
                if score > bestScore {
                    bestScore = score
                    defaults.set(score, forKey: Self.bestScoreKey)
                }
            }
        }

        reefs.removeAll { $0.x < -100 }
        spawnGateIfNeeded()

        if hasCollision() {
            endGame()
        }
    }

    func resetBestScoreForTesting() {
        bestScore = 0
        defaults.removeObject(forKey: Self.bestScoreKey)
    }

    private func spawnGateIfNeeded() {
        let spacing = max(238, worldSize.width * 0.62)
        let triggerX = worldSize.width + 125 - spacing
        if reefs.last?.x ?? -.infinity < triggerX {
            spawnGate(at: worldSize.width + 125)
        }
    }

    private func spawnGate(at x: CGFloat) {
        let gapHeight = max(164, 214 - CGFloat(min(score, 20)) * 2.25)
        let margin: CGFloat = 66
        let minimum = gapHeight / 2 + margin
        let maximum = worldSize.height - gapHeight / 2 - margin
        let range = max(0, maximum - minimum)
        let center = minimum + randomUnit() * range

        reefs.append(
            ReefGate(
                id: nextGateID,
                x: x,
                gapCenterY: center,
                gapHeight: gapHeight,
                hasScored: false,
                seed: randomState
            )
        )
        nextGateID += 1
    }

    private func randomUnit() -> CGFloat {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(Double(randomState >> 11) / Double(1 << 53))
    }

    private func hasCollision() -> Bool {
        let hitbox = CGRect(
            x: submarineX - 27,
            y: submarineY - 13,
            width: 54,
            height: 26
        )

        if hitbox.minY < 30 || hitbox.maxY > worldSize.height - 34 {
            return true
        }

        for reef in reefs where abs(reef.x - submarineX) < 66 {
            let horizontalOverlap = hitbox.maxX > reef.x - 38 && hitbox.minX < reef.x + 38
            let hitsRock = hitbox.minY < reef.topEdge || hitbox.maxY > reef.bottomEdge
            if horizontalOverlap && hitsRock {
                return true
            }
        }
        return false
    }

    private func endGame() {
        state = .gameOver
        isThrusting = false
        submarineVelocity = 0
    }

    @objc private func frameDidFire(_ link: CADisplayLink) {
        defer { previousTimestamp = link.timestamp }
        guard let previousTimestamp else {
            self.previousTimestamp = link.timestamp
            return
        }

        let deltaTime = link.timestamp - previousTimestamp
        elapsed += min(deltaTime, 1.0 / 20.0)
        step(deltaTime: deltaTime)
    }
}
