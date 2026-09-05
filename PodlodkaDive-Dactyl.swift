import SwiftUI
import Combine
import Foundation
import QuartzCore
import UIKit

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


struct GameCanvas: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.13, blue: 0.68),
                    Color(red: 0.27, green: 0.02, blue: 0.55),
                    Color(red: 0.015, green: 0.025, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                drawWater(in: &context, size: size)
                drawDistantTerrain(in: &context, size: size)
                drawAmbientBubbles(in: &context, size: size)

                for reef in engine.reefs {
                    drawReef(reef, in: &context, size: size)
                }

                drawSubmarine(in: &context)
                drawForeground(in: &context, size: size)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func drawWater(in context: inout GraphicsContext, size: CGSize) {
        let glowCenter = CGPoint(x: size.width * 0.18, y: size.height * 0.08)
        context.fill(
            Path(ellipseIn: CGRect(x: -size.width * 0.4, y: -120, width: size.width * 1.3, height: size.height * 0.55)),
            with: .radialGradient(
                Gradient(colors: [.cyan.opacity(0.26), .clear]),
                center: glowCenter,
                startRadius: 5,
                endRadius: size.width * 0.7
            )
        )

        for index in 0..<5 {
            let drift = CGFloat(sin(engine.elapsed * 0.35 + Double(index))) * 22
            var ray = Path()
            let x = size.width * (0.02 + CGFloat(index) * 0.22) + drift
            ray.move(to: CGPoint(x: x, y: -20))
            ray.addLine(to: CGPoint(x: x + 52, y: -20))
            ray.addLine(to: CGPoint(x: x + 145, y: size.height * 0.72))
            ray.addLine(to: CGPoint(x: x + 80, y: size.height * 0.72))
            ray.closeSubpath()
            context.fill(ray, with: .color(.cyan.opacity(0.025)))
        }

        var surface = Path()
        surface.move(to: .zero)
        let waveStep: CGFloat = 20
        var x: CGFloat = 0
        while x <= size.width + waveStep {
            let y = 8 + sin(x * 0.045 + CGFloat(engine.elapsed) * 1.8) * 3
            surface.addLine(to: CGPoint(x: x, y: y))
            x += waveStep
        }
        surface.addLine(to: CGPoint(x: size.width, y: 0))
        surface.closeSubpath()
        context.fill(surface, with: .color(.white.opacity(0.16)))
    }

    private func drawDistantTerrain(in context: inout GraphicsContext, size: CGSize) {
        for layer in 0..<2 {
            let baseY = size.height - CGFloat(68 + layer * 35)
            let speed = CGFloat(layer + 1) * 7
            let offset = CGFloat(engine.elapsed) * speed
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: baseY))

            let step: CGFloat = 54
            var x: CGFloat = -step
            while x < size.width + step {
                let phaseX = x + offset.truncatingRemainder(dividingBy: step * 4)
                let y = baseY - (sin(phaseX * 0.021 + CGFloat(layer)) + 1) * CGFloat(10 + layer * 8)
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(Color.indigo.opacity(layer == 0 ? 0.24 : 0.16)))
        }
    }

    private func drawAmbientBubbles(in context: inout GraphicsContext, size: CGSize) {
        for index in 0..<16 {
            let baseX = CGFloat((index * 83) % 397) / 397 * size.width
            let speed = CGFloat(10 + (index * 7) % 18)
            let travel = CGFloat(engine.elapsed) * speed
            let baseY = CGFloat((index * 131) % 701) / 701 * size.height
            let y = size.height - (baseY + travel).truncatingRemainder(dividingBy: size.height + 50)
            let x = baseX + sin(CGFloat(engine.elapsed) * 0.7 + CGFloat(index)) * 7
            let radius = CGFloat(1.5 + Double(index % 4))
            let bubble = Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
            context.stroke(bubble, with: .color(.white.opacity(0.18)), lineWidth: 1)
        }
    }

    private func drawReef(_ reef: ReefGate, in context: inout GraphicsContext, size: CGSize) {
        drawRockColumn(
            centerX: reef.x,
            from: 0,
            to: reef.topEdge,
            opensDownward: true,
            seed: reef.seed,
            in: &context
        )
        drawRockColumn(
            centerX: reef.x,
            from: reef.bottomEdge,
            to: size.height,
            opensDownward: false,
            seed: reef.seed &+ 17,
            in: &context
        )

        drawCoral(at: CGPoint(x: reef.x, y: reef.topEdge - 4), flipped: true, in: &context)
        drawCoral(at: CGPoint(x: reef.x, y: reef.bottomEdge + 5), flipped: false, in: &context)
    }

    private func drawRockColumn(
        centerX: CGFloat,
        from startY: CGFloat,
        to endY: CGFloat,
        opensDownward: Bool,
        seed: UInt64,
        in context: inout GraphicsContext
    ) {
        let halfWidth: CGFloat = 39
        let left = centerX - halfWidth
        let right = centerX + halfWidth
        let lipY = opensDownward ? endY : startY
        var path = Path()
        path.move(to: CGPoint(x: left, y: startY))
        path.addLine(to: CGPoint(x: right, y: startY))

        let height = max(1, endY - startY)
        for index in 0...7 {
            let fraction = CGFloat(index) / 7
            let y = startY + height * fraction
            let wobble = sin(CGFloat(index) * 2.1 + CGFloat(seed % 11)) * 5
            path.addLine(to: CGPoint(x: right + wobble, y: y))
        }

        path.addLine(to: CGPoint(x: right + 10, y: lipY))
        path.addLine(to: CGPoint(x: centerX + 17, y: lipY + (opensDownward ? 10 : -10)))
        path.addLine(to: CGPoint(x: centerX - 17, y: lipY + (opensDownward ? 5 : -5)))
        path.addLine(to: CGPoint(x: left - 10, y: lipY))

        for index in stride(from: 7, through: 0, by: -1) {
            let fraction = CGFloat(index) / 7
            let y = startY + height * fraction
            let wobble = cos(CGFloat(index) * 1.8 + CGFloat(seed % 7)) * 5
            path.addLine(to: CGPoint(x: left + wobble, y: y))
        }
        path.closeSubpath()

        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.18, green: 0.05, blue: 0.31),
                    Color(red: 0.43, green: 0.04, blue: 0.58),
                    Color(red: 0.14, green: 0.02, blue: 0.25)
                ]),
                startPoint: CGPoint(x: left, y: 0),
                endPoint: CGPoint(x: right, y: 0)
            )
        )
        context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 2)

        for index in 0..<4 {
            let dotY = startY + height * CGFloat(index + 1) / 5
            let dotX = centerX + (index.isMultiple(of: 2) ? -13 : 12)
            let dot = Path(ellipseIn: CGRect(x: dotX - 4, y: dotY - 4, width: 8, height: 8))
            context.fill(dot, with: .color(.black.opacity(0.16)))
        }
    }

    private func drawCoral(
        at point: CGPoint,
        flipped: Bool,
        in context: inout GraphicsContext
    ) {
        let direction: CGFloat = flipped ? -1 : 1
        var coral = Path()
        coral.move(to: point)
        coral.addCurve(
            to: CGPoint(x: point.x - 17, y: point.y + 17 * direction),
            control1: CGPoint(x: point.x - 4, y: point.y + 7 * direction),
            control2: CGPoint(x: point.x - 13, y: point.y + 8 * direction)
        )
        coral.move(to: CGPoint(x: point.x - 5, y: point.y + 5 * direction))
        coral.addCurve(
            to: CGPoint(x: point.x + 2, y: point.y + 24 * direction),
            control1: CGPoint(x: point.x - 5, y: point.y + 12 * direction),
            control2: CGPoint(x: point.x + 2, y: point.y + 14 * direction)
        )
        coral.move(to: CGPoint(x: point.x + 1, y: point.y + 7 * direction))
        coral.addCurve(
            to: CGPoint(x: point.x + 20, y: point.y + 17 * direction),
            control1: CGPoint(x: point.x + 8, y: point.y + 7 * direction),
            control2: CGPoint(x: point.x + 11, y: point.y + 16 * direction)
        )
        context.stroke(
            coral,
            with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.36, blue: 0.42), Color.orange]),
                startPoint: point,
                endPoint: CGPoint(x: point.x, y: point.y + 25 * direction)
            ),
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSubmarine(in context: inout GraphicsContext) {
        let bob = engine.state == .ready ? CGFloat(sin(engine.elapsed * 2)) * 7 : 0
        let center = CGPoint(x: engine.submarineX, y: engine.submarineY + bob)

        for index in 0..<4 {
            let phase = (CGFloat(engine.elapsed) * CGFloat(34 + index * 5) + CGFloat(index * 17))
                .truncatingRemainder(dividingBy: 78)
            let radius = CGFloat(2 + index)
            let x = center.x - 43 - phase
            let y = center.y + sin(phase * 0.11 + CGFloat(index)) * 9
            let bubble = Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
            context.stroke(bubble, with: .color(.cyan.opacity(0.56)), lineWidth: 1.5)
        }

        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(engine.submarineRotationRadians))

            var tail = Path()
            tail.move(to: CGPoint(x: -27, y: -5))
            tail.addLine(to: CGPoint(x: -48, y: -18))
            tail.addLine(to: CGPoint(x: -44, y: 0))
            tail.addLine(to: CGPoint(x: -48, y: 18))
            tail.addLine(to: CGPoint(x: -25, y: 7))
            tail.closeSubpath()
            layer.fill(tail, with: .color(Color(red: 0.76, green: 0.12, blue: 0.42)))

            let propellerShift = CGFloat(sin(engine.elapsed * (engine.isThrustActive ? 24 : 6))) * 4
            let propeller = Path(
                roundedRect: CGRect(x: -54, y: -15 + propellerShift, width: 7, height: 30 - propellerShift * 2),
                cornerRadius: 4
            )
            layer.fill(propeller, with: .color(.white.opacity(0.9)))

            let body = Path(roundedRect: CGRect(x: -35, y: -19, width: 73, height: 38), cornerRadius: 19)
            layer.fill(
                body,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.49, blue: 0.22), Color(red: 0.98, green: 0.18, blue: 0.42)]),
                    startPoint: CGPoint(x: 0, y: -20),
                    endPoint: CGPoint(x: 0, y: 20)
                )
            )
            layer.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 2.3)

            let cabin = Path(roundedRect: CGRect(x: -10, y: -29, width: 28, height: 16), cornerRadius: 8)
            layer.fill(cabin, with: .color(Color(red: 0.34, green: 0.03, blue: 0.55)))
            layer.stroke(cabin, with: .color(.white.opacity(0.82)), lineWidth: 2)

            var periscope = Path()
            periscope.move(to: CGPoint(x: 4, y: -28))
            periscope.addLine(to: CGPoint(x: 4, y: -38))
            periscope.addLine(to: CGPoint(x: 13, y: -38))
            layer.stroke(periscope, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            for windowX in [-13.0, 9.0] {
                let ring = Path(ellipseIn: CGRect(x: windowX - 7, y: -7, width: 14, height: 14))
                layer.fill(ring, with: .color(.white.opacity(0.95)))
                let glass = Path(ellipseIn: CGRect(x: windowX - 4.5, y: -4.5, width: 9, height: 9))
                layer.fill(glass, with: .color(Color.cyan.opacity(0.9)))
            }

            var fin = Path()
            fin.move(to: CGPoint(x: -1, y: 17))
            fin.addLine(to: CGPoint(x: 13, y: 29))
            fin.addLine(to: CGPoint(x: 21, y: 17))
            fin.closeSubpath()
            layer.fill(fin, with: .color(Color(red: 0.73, green: 0.08, blue: 0.43)))
        }
    }

    private func drawForeground(in context: inout GraphicsContext, size: CGSize) {
        var floor = Path()
        floor.move(to: CGPoint(x: 0, y: size.height - 30))
        let step: CGFloat = 28
        var x: CGFloat = 0
        while x <= size.width + step {
            let y = size.height - 28 + sin(x * 0.06 + CGFloat(engine.elapsed) * 0.25) * 5
            floor.addLine(to: CGPoint(x: x, y: y))
            x += step
        }
        floor.addLine(to: CGPoint(x: size.width, y: size.height))
        floor.addLine(to: CGPoint(x: 0, y: size.height))
        floor.closeSubpath()
        context.fill(floor, with: .color(Color(red: 0.055, green: 0.015, blue: 0.12)))

        for index in 0..<8 {
            let plantX = CGFloat(index) * size.width / 7 + 8
            let sway = CGFloat(sin(engine.elapsed * 1.1 + Double(index))) * 5
            var plant = Path()
            plant.move(to: CGPoint(x: plantX, y: size.height))
            plant.addCurve(
                to: CGPoint(x: plantX + sway, y: size.height - CGFloat(24 + (index % 3) * 9)),
                control1: CGPoint(x: plantX - 8, y: size.height - 10),
                control2: CGPoint(x: plantX + sway + 7, y: size.height - 19)
            )
            context.stroke(plant, with: .color(.cyan.opacity(0.25)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}


struct ContentView: View {
    @StateObject private var engine = GameEngine()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameCanvas(engine: engine)
                    .contentShape(Rectangle())
                    .gesture(thrustGesture)

                VStack(spacing: 0) {
                    hud
                    Spacer()
                    if engine.state == .playing && engine.score == 0 {
                        controlHint
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)

                switch engine.state {
                case .ready:
                    startCard
                case .paused:
                    pauseCard
                case .gameOver:
                    gameOverCard
                case .playing:
                    EmptyView()
                }
            }
            .onAppear {
                engine.resize(to: proxy.size)
                engine.startLoop()
            }
            .onDisappear {
                engine.stopLoop()
            }
            .onChange(of: proxy.size) { newSize in
                engine.resize(to: newSize)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: engine.score) { newScore in
            if newScore > 0 {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        .onChange(of: engine.state) { newState in
            if newState == .gameOver {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private var thrustGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in engine.setThrusting(true) }
            .onEnded { _ in engine.setThrusting(false) }
    }

    private var hud: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("PODLODKA")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.8)
                Text("iOS CREW · DIVE")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.65), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))

            Spacer()

            if engine.state != .ready {
                scorePill
                    .transition(.scale.combined(with: .opacity))
            }

            if engine.state == .playing || engine.state == .paused {
                Button(action: engine.togglePause) {
                    Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial.opacity(0.72), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(engine.state == .paused ? "Продолжить" : "Пауза")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: engine.state)
    }

    private var scorePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.system(size: 13, weight: .bold))
            Text("\(engine.score)")
                .font(.system(size: 19, weight: .black, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.15, green: 0.02, blue: 0.28))
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.white, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Счёт: \(engine.score)")
    }

    private var startCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text("ГЛУБИНА")
                Text("ЗОВЁТ")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 1, green: 0.68, blue: 0.22), Color(red: 1, green: 0.25, blue: 0.46)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .font(.system(size: 48, weight: .black, design: .rounded))
            .minimumScaleFactor(0.7)
            .lineSpacing(-8)

            Text("Проведи подлодку между рифами.\nВ воде всё решают плавность и инерция.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button(action: engine.startGame) {
                HStack(spacing: 9) {
                    Text("В ПОГРУЖЕНИЕ")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.20, green: 0.02, blue: 0.35))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(.white, in: Capsule())
            }
            .buttonStyle(SpringButtonStyle())

            HStack(spacing: 7) {
                Image(systemName: "hand.tap.fill")
                Text("Удерживай экран, чтобы всплывать")
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
        }
        .padding(26)
        .frame(maxWidth: 370)
        .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 35, y: 18)
        .padding(.horizontal, 22)
        .accessibilityElement(children: .contain)
    }

    private var controlHint: some View {
        HStack(spacing: 14) {
            Image(systemName: engine.isThrustActive ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 27))
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.isThrustActive ? "ТЯГА ВКЛЮЧЕНА" : "ЗАЖМИ ЭКРАН")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                Text(engine.isThrustActive ? "Подлодка всплывает" : "Отпустишь — погружение")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: engine.isThrustActive)
        .allowsHitTesting(false)
    }

    private var pauseCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 52))
            Text("ТИХАЯ ВОДА")
                .font(.system(size: 30, weight: .black, design: .rounded))
            Text("Экспедиция на паузе")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
            Button("ПРОДОЛЖИТЬ", action: engine.togglePause)
                .buttonStyle(PodlodkaButtonStyle())
        }
        .modalCard()
    }

    private var gameOverCard: some View {
        VStack(spacing: 18) {
            Text("ЭХОЛОКАТОР\nПОТЕРЯН")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .lineSpacing(-3)

            HStack(spacing: 10) {
                resultStat(value: engine.score, title: "РИФОВ")
                resultStat(value: engine.bestScore, title: "РЕКОРД")
            }

            Button(action: engine.startGame) {
                Label("ЕЩЁ ПОПЫТКА", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(PodlodkaButtonStyle())

            Text("Можно также коснуться воды")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .modalCard()
    }

    private func resultStat(value: Int, title: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 32, weight: .black, design: .rounded))
            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SpringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct PodlodkaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.22, green: 0.02, blue: 0.36))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private extension View {
    func modalCard() -> some View {
        self
            .padding(26)
            .frame(maxWidth: 340)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial.opacity(0.88), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 32, y: 16)
            .padding(.horizontal, 24)
    }
}
