import SwiftUI
import UIKit

struct GameView: View {
    @StateObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMap = false

    init(engine: GameEngine = GameEngine()) {
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameCanvas(engine: engine)
                if engine.state == .ready {
                    welcome(size: proxy.size, insets: proxy.safeAreaInsets)
                } else {
                    instruments(insets: proxy.safeAreaInsets)
                        .allowsHitTesting(engine.state == .playing)
                        .accessibilityHidden(engine.state != .playing)
                    if engine.state == .playing {
                        objectivePointer(size: proxy.size)
                        controls(insets: proxy.safeAreaInsets)
                    }
                    if engine.state != .playing {
                        OceanPalette.ink.opacity(0.78).ignoresSafeArea()
                        if showingMap {
                            mapPanel(height: proxy.size.height)
                        } else {
                            resultPanel
                        }
                    }
                }
            }
            .onAppear { engine.resize(to: proxy.size); engine.startLoop() }
            .onDisappear { engine.stopLoop() }
            .onChange(of: proxy.size) { _, size in engine.resize(to: size) }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in if phase != .active { engine.pause() } }
        .sensoryFeedback(.selection, trigger: engine.pickupCount)
        .sensoryFeedback(.error, trigger: engine.damageCount)
        .sensoryFeedback(.success, trigger: engine.state == .completed)
        .preferredColorScheme(.dark)
    }

    private func welcome(size: CGSize, insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack {
                brand
                Spacer()
                Label("\(engine.bestScore)", systemImage: "trophy")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OceanPalette.gold)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(OceanPalette.gold.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(OceanPalette.gold.opacity(0.15), lineWidth: 1))
                    .accessibilityLabel("Лучшая доставленная добыча: \(engine.bestScore)")
            }
            .padding(.top, max(insets.top, 48) + 12)
            VStack(spacing: 12) {
                Text("СВОБОДНЫЙ ОКЕАН")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(3).foregroundStyle(OceanPalette.teal)
                Text("Курс на глубину.")
                    .font(.system(size: size.height < 720 ? 35 : 41, weight: .bold, design: .rounded))
                    .tracking(-1.5).foregroundStyle(OceanPalette.white)
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text("Найди чёрный ящик. Вернись с добычей.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(OceanPalette.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, size.height * 0.045)
            Spacer(minLength: 0)
            VStack(spacing: size.height < 720 ? 16 : 22) {
                HStack(spacing: 7) {
                    Circle().fill(OceanPalette.teal).frame(width: 4, height: 4)
                    Text("ЭКСПЕДИЦИЯ 01 / ЗАТОНУВШИЙ ASTER")
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                }.foregroundStyle(OceanPalette.teal.opacity(0.85))
                HStack(spacing: 0) {
                    instruction(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "Свободный курс", detail: "Тяни стик в любую сторону")
                    Rectangle().fill(OceanPalette.teal.opacity(0.15)).frame(width: 1, height: 48)
                    instruction(icon: "dot.radiowaves.left.and.right", title: "Сонар и форсаж", detail: "Ищи. Маневрируй. Исследуй.")
                }
                .padding(.vertical, 17)
                .background(OceanPalette.ink.opacity(0.45), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(OceanPalette.teal.opacity(0.12), lineWidth: 1))
                Button {
                    showingMap = false
                    engine.startGame()
                } label: {
                    HStack { Spacer(); Text("Начать экспедицию"); Spacer(); Image(systemName: "arrow.right") }
                }
                .buttonStyle(DiveButtonStyle()).accessibilityIdentifier("startDive")
                Text("Береги корпус и заряд на обратный путь")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OceanPalette.muted)
            }
            .padding(.bottom, max(insets.bottom, 24) + 16)
        }
        .padding(.horizontal, 26)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Text("18").font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(OceanPalette.teal).frame(width: 35, height: 35)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanPalette.teal.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("PODLODKA").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(OceanPalette.white)
                Text("D I V E  /  iOS CREW").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(OceanPalette.muted)
            }
        }
    }

    private func instruction(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(OceanPalette.gold)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(OceanPalette.white)
            Text(detail).font(.system(size: 9)).foregroundStyle(OceanPalette.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity)
    }

    private func instruments(insets: EdgeInsets) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ЭКСПЕДИЦИЯ 01 · \(engine.depth) М")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.2).foregroundStyle(OceanPalette.muted)
                    Text(engine.hasBlackBox ? "Вернись на базу" : "Найди чёрный ящик")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(engine.hasBlackBox ? OceanPalette.teal : OceanPalette.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .allowsHitTesting(false)
                Spacer(minLength: 0)
                hudButton("map", label: "Карта экспедиции", id: "openMap") { engine.pause(); showingMap = true }
                hudButton("pause.fill", label: "Пауза", id: "pauseDive", action: engine.pause)
            }
            HStack(spacing: 13) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11))
                    Text("\(Int(ceil(engine.energy)))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(minWidth: 35, alignment: .leading)
                    Capsule().fill(OceanPalette.teal.opacity(0.14)).frame(width: 40, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(engine.energy < 25 ? OceanPalette.danger : OceanPalette.teal)
                                .frame(width: 40 * engine.energy / 100, height: 4)
                        }
                }
                .foregroundStyle(engine.energy < 25 ? OceanPalette.danger : OceanPalette.teal)
                .accessibilityElement(children: .ignore).accessibilityLabel("Энергия: \(Int(engine.energy)) процентов")
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Image(systemName: index < engine.hull ? "heart.fill" : "heart")
                            .font(.system(size: 11)).foregroundStyle(index < engine.hull ? OceanPalette.danger : OceanPalette.muted.opacity(0.4))
                    }
                    if engine.hasShield { Image(systemName: "shield.fill").font(.system(size: 11)).foregroundStyle(OceanPalette.blue) }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Корпус: \(engine.hull) из 3. \(engine.hasShield ? "Щит активен" : "")")
                Spacer(minLength: 0)
                Label("\(engine.cargoValue)", systemImage: "shippingbox")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(OceanPalette.gold)
                    .accessibilityLabel("Груз на борту: \(engine.cargoValue)")
            }
            .allowsHitTesting(false)
            HStack(spacing: 6) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.radians(atan2(engine.target.y - engine.position.y, engine.target.x - engine.position.x) + .pi / 2))
                Text("\(engine.hasBlackBox ? "БАЗА" : "СИГНАЛ") · \(engine.targetDistance) М")
                    .tracking(1)
                Spacer()
                if engine.hasBlackBox { Label("ЯЩИК НА БОРТУ", systemImage: "checkmark").foregroundStyle(OceanPalette.teal) }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(OceanPalette.gold.opacity(0.85)).allowsHitTesting(false)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, max(insets.top, 48) + 9)
        .background(alignment: .top) {
            LinearGradient(colors: [OceanPalette.ink.opacity(0.92), OceanPalette.ink.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 190).allowsHitTesting(false)
        }
    }

    private func hudButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OceanPalette.white).frame(width: 42, height: 42)
                .background(OceanPalette.ink.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(OceanPalette.teal.opacity(0.22), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private func controls(insets: EdgeInsets) -> some View {
        VStack(spacing: 4) {
            Spacer()
            if engine.energy < 25 {
                Label("Мало энергии — ищи батарею или возвращайся", systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(OceanPalette.danger)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(OceanPalette.ink.opacity(0.85), in: Capsule()).allowsHitTesting(false)
            }
            if engine.noticeRemaining > 0 {
                Text(engine.notice).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OceanPalette.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(OceanPalette.ink.opacity(0.85), in: Capsule())
                    .padding(.horizontal, 16).allowsHitTesting(false)
            }
            HStack(alignment: .center, spacing: 0) {
                SteeringPad(onInput: engine.setSteering)
                    .frame(width: 174, height: 158)
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        AbilityButton(icon: "dot.radiowaves.left.and.right", title: "СОНАР",
                                      detail: engine.sonarCooldown > 0 ? "\(Int(ceil(engine.sonarCooldown))) с" : "Поиск",
                                      progress: 1 - engine.sonarCooldown / 8, enabled: engine.canSonar,
                                      color: OceanPalette.teal, action: engine.activateSonar)
                            .accessibilityIdentifier("sonar")
                        AbilityButton(icon: "bolt.fill", title: "ФОРСАЖ",
                                      detail: engine.boostCooldown > 0 ? "\(Int(ceil(engine.boostCooldown))) с" : "−7 энергии",
                                      progress: 1 - engine.boostCooldown / 4.5, enabled: engine.canBoost,
                                      color: OceanPalette.gold, action: engine.activateBoost)
                            .accessibilityIdentifier("boost")
                    }
                    if engine.runElapsed < 12 {
                        Text("Отпусти стик, чтобы зависнуть")
                            .font(.system(size: 8)).foregroundStyle(OceanPalette.muted)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.trailing, 18)
            }
            .padding(.bottom, max(insets.bottom, 20))
            .background(LinearGradient(colors: [.clear, OceanPalette.ink.opacity(0.82)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        }
    }

    private func objectivePointer(size: CGSize) -> some View {
        let point = engine.screenPoint(engine.target)
        let scale = size.width / engine.viewport.width
        let bounds = CGRect(x: 29, y: 192, width: engine.viewport.width - 58, height: max(80, engine.viewport.height - 415))
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        return Group {
            if !bounds.contains(point) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 16, weight: .medium))
                    .rotationEffect(.radians(atan2(engine.target.y - engine.position.y, engine.target.x - engine.position.x) + .pi / 2))
                    .foregroundStyle(engine.hasBlackBox ? OceanPalette.teal : OceanPalette.gold)
                    .frame(width: 33, height: 33)
                    .background(OceanPalette.ink.opacity(0.7), in: Circle())
                    .overlay(Circle().stroke(OceanPalette.gold.opacity(0.25), lineWidth: 1))
                    .position(x: x * scale, y: y * scale)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func mapPanel(height: CGFloat) -> some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("КАРТА ЭКСПЕДИЦИИ").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(OceanPalette.teal)
                    Text("Сектор «Aster»").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(OceanPalette.white)
                }
                Spacer()
                Text("ПАУЗА").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(OceanPalette.muted)
            }
            ExpeditionMap(engine: engine).frame(height: min(395, height * 0.49))
                .background(OceanPalette.ink.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 9) {
                HStack(spacing: 13) {
                    mapKey("circle.fill", "Ты", .white)
                    mapKey("house.fill", "База", OceanPalette.teal)
                    mapKey("shippingbox.fill", "Цель", OceanPalette.gold)
                    mapKey("xmark", "Мины", OceanPalette.danger)
                }
                HStack(spacing: 15) {
                    mapKey("battery.100percent", "Батарея", OceanPalette.teal)
                    mapKey("shield", "Щит", OceanPalette.blue)
                    mapKey("diamond", "Образец", OceanPalette.gold)
                }
            }
            Text("Сонар отмечает находки. Линия — пройденный путь.")
                .font(.system(size: 10)).foregroundStyle(OceanPalette.muted).multilineTextAlignment(.center)
            Button {
                showingMap = false
                engine.togglePause()
            } label: {
                HStack { Spacer(); Text("Вернуться в океан"); Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(DiveButtonStyle()).accessibilityIdentifier("closeMap")
        }
        .padding(22).frame(maxWidth: 380)
        .background(Color(red: 0.035, green: 0.15, blue: 0.20), in: RoundedRectangle(cornerRadius: 27))
        .overlay(RoundedRectangle(cornerRadius: 27).stroke(OceanPalette.teal.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private func mapKey(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(size: 10)).foregroundStyle(color)
    }

    private var resultPanel: some View {
        let paused = engine.state == .paused
        let success = engine.state == .completed
        let title = paused ? "Можно выдохнуть." : (success ? "Груз доставлен." : "Океан сильнее.")
        let detail = paused ? "Экспедиция на паузе. Заряд сохраняется." : (success ? "Чёрный ящик на базе. Хорошая работа, капитан." : (engine.failureReason == .energy ? "Заряд закончился. Груз остался на глубине." : "Корпус не выдержал. Груз остался на глубине."))
        return VStack(spacing: 22) {
            Image(systemName: paused ? "pause.fill" : (success ? "shippingbox.fill" : "water.waves"))
                .font(.system(size: 28, weight: .medium)).foregroundStyle(success ? OceanPalette.gold : OceanPalette.teal)
                .frame(width: 72, height: 72)
                .background(OceanPalette.teal.opacity(0.07), in: Circle())
                .overlay(Circle().stroke(OceanPalette.teal.opacity(0.15), lineWidth: 1))
            VStack(spacing: 10) {
                Text(paused ? "ТИХАЯ ВОДА" : (engine.isNewRecord ? "НОВЫЙ РЕКОРД ЭКСПЕДИЦИИ" : "ЭКСПЕДИЦИЯ ЗАВЕРШЕНА"))
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(OceanPalette.teal)
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.8)
                    .foregroundStyle(OceanPalette.white).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail).font(.system(size: 13)).foregroundStyle(OceanPalette.muted).multilineTextAlignment(.center).lineSpacing(3)
            }
            HStack(spacing: 0) {
                resultStat(paused ? engine.cargoValue : engine.score, title: paused ? "ГРУЗ НА БОРТУ" : "ДОСТАВЛЕНО", highlighted: true)
                Rectangle().fill(OceanPalette.teal.opacity(0.15)).frame(width: 1, height: 44)
                resultStat(engine.bestScore, title: "ЛУЧШАЯ ДОБЫЧА", highlighted: false)
            }
            .padding(.vertical, 16).background(OceanPalette.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 12) {
                Button {
                    if paused { engine.togglePause() } else { engine.startGame() }
                } label: {
                    HStack { Spacer(); Text(paused ? "Продолжить" : "Новая экспедиция"); Spacer(); Image(systemName: paused ? "play.fill" : "arrow.clockwise") }
                }.buttonStyle(DiveButtonStyle()).accessibilityIdentifier(paused ? "resumeDive" : "retryDive")
                if paused {
                    Button("Открыть карту") { showingMap = true }
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(OceanPalette.teal).frame(minHeight: 35)
                }
                Button("На поверхность") { showingMap = false; engine.returnToMenu() }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(OceanPalette.muted).frame(minHeight: 35)
                    .accessibilityIdentifier("returnToMenu")
            }
        }
        .padding(25).frame(maxWidth: 360)
        .background(Color(red: 0.035, green: 0.15, blue: 0.20), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(OceanPalette.teal.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 25)
    }

    private func resultStat(_ value: Int, title: String, highlighted: Bool) -> some View {
        VStack(spacing: 6) {
            Text("\(value)").font(.system(size: 33, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(highlighted ? OceanPalette.white : OceanPalette.gold)
            Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(OceanPalette.muted)
        }.frame(maxWidth: .infinity)
    }
}

/// A native touch surface keeps ownership of the steering finger while the
/// other thumb presses an ability, and handles cancellation explicitly.
private struct SteeringPad: UIViewRepresentable {
    let onInput: (CGVector) -> Void

    func makeUIView(context: Context) -> SteeringSurface {
        let view = SteeringSurface()
        view.onInput = onInput
        return view
    }

    func updateUIView(_ view: SteeringSurface, context: Context) { view.onInput = onInput }
    static func dismantleUIView(_ view: SteeringSurface, coordinator: ()) { view.releaseInput() }
}

private final class SteeringSurface: UIView {
    var onInput: ((CGVector) -> Void)?
    private var finger: UITouch?
    private var origin: CGPoint?
    private var knob = CGVector.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Руль подлодки. Тяни в нужном направлении. Отпусти, чтобы остановиться."
        accessibilityIdentifier = "steeringPad"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard finger == nil, let touch = touches.first else { return }
        finger = touch
        let point = touch.location(in: self)
        origin = CGPoint(x: min(max(point.x, 53), bounds.width - 53), y: min(max(point.y, 53), bounds.height - 53))
        updateInput(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let finger, touches.contains(finger) else { return }
        updateInput(finger.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let finger, touches.contains(finger) else { return }
        releaseInput()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releaseInput() }

    func releaseInput() {
        finger = nil
        origin = nil
        knob = .zero
        onInput?(.zero)
        setNeedsDisplay()
    }

    private func updateInput(_ point: CGPoint) {
        guard let origin else { return }
        let dx = point.x - origin.x, dy = point.y - origin.y
        let length = hypot(dx, dy)
        let scale = length > 44 ? 44 / length : 1
        knob = CGVector(dx: dx * scale, dy: dy * scale)
        onInput?(CGVector(dx: knob.dx / 44, dy: knob.dy / 44))
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = origin ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let teal = UIColor(OceanPalette.teal)
        func circle(_ center: CGPoint, radius: CGFloat, fill: UIColor?, stroke: UIColor?) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if let fill { context.setFillColor(fill.cgColor); context.fillEllipse(in: rect) }
            if let stroke { context.setStrokeColor(stroke.cgColor); context.setLineWidth(1); context.strokeEllipse(in: rect) }
        }
        circle(center, radius: 53, fill: UIColor(OceanPalette.ink).withAlphaComponent(0.3), stroke: teal.withAlphaComponent(finger == nil ? 0.18 : 0.45))
        circle(center, radius: 38, fill: nil, stroke: teal.withAlphaComponent(0.08))
        context.setStrokeColor(teal.withAlphaComponent(0.23).cgColor)
        context.move(to: CGPoint(x: center.x - 5, y: center.y)); context.addLine(to: CGPoint(x: center.x + 5, y: center.y))
        context.move(to: CGPoint(x: center.x, y: center.y - 5)); context.addLine(to: CGPoint(x: center.x, y: center.y + 5))
        context.strokePath()
        circle(CGPoint(x: center.x + knob.dx, y: center.y + knob.dy), radius: 21.5,
               fill: teal.withAlphaComponent(finger == nil ? 0.09 : 0.28), stroke: teal.withAlphaComponent(0.55))
    }
}

private struct AbilityButton: View {
    let icon: String
    let title: String
    let detail: String
    let progress: Double
    let enabled: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(OceanPalette.ink.opacity(0.85))
                    Circle().stroke(color.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(color.opacity(enabled ? 0.7 : 0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(color.opacity(enabled ? 1 : 0.4))
                }.frame(width: 55, height: 55)
                Text(title).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(color)
                Text(detail).font(.system(size: 9)).foregroundStyle(OceanPalette.muted)
            }.frame(width: 64)
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel("\(title), \(detail)")
    }
}

private struct ExpeditionMap: View {
    @ObservedObject var engine: GameEngine
    var body: some View {
        Canvas { context, size in
            let scale = min((size.width - 28) / engine.level.size.width, (size.height - 32) / engine.level.size.height)
            let offset = CGPoint(x: (size.width - engine.level.size.width * scale) / 2, y: 16)
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
            for zone in engine.level.currents {
                let rect = CGRect(x: zone.bounds.minX * scale + offset.x, y: zone.bounds.minY * scale + offset.y,
                                  width: zone.bounds.width * scale, height: zone.bounds.height * scale)
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(OceanPalette.blue.opacity(0.10)))
            }
            for rock in engine.level.rocks {
                var path = Path(); path.addLines(rock.vertices.map(point)); path.closeSubpath()
                context.fill(path, with: .color(OceanPalette.teal.opacity(0.13)))
                context.stroke(path, with: .color(OceanPalette.teal.opacity(0.28)), lineWidth: 0.7)
            }
            var trail = Path(); trail.addLines(engine.trail.map(point))
            context.stroke(trail, with: .color(OceanPalette.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            for mine in engine.mines where mine.phase != .spent {
                let p = point(mine.position)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 3, y: p.y - 3)); cross.addLine(to: CGPoint(x: p.x + 3, y: p.y + 3))
                cross.move(to: CGPoint(x: p.x + 3, y: p.y - 3)); cross.addLine(to: CGPoint(x: p.x - 3, y: p.y + 3))
                context.stroke(cross, with: .color(OceanPalette.danger.opacity(0.8)), lineWidth: 1.5)
            }
            for pickup in engine.pickups where !pickup.collected && pickup.kind != .blackBox && engine.revealedPickups.contains(pickup.id) {
                let p = point(pickup.position)
                let color = pickup.kind == .battery ? OceanPalette.teal : (pickup.kind == .shield ? OceanPalette.blue : OceanPalette.gold)
                let rect = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                context.fill(Path(roundedRect: rect, cornerRadius: pickup.kind == .battery ? 1 : 3), with: .color(color))
            }
            let base = point(engine.level.base), wreck = point(engine.level.wreck), boat = point(engine.position)
            context.stroke(Path(ellipseIn: CGRect(x: base.x - 6, y: base.y - 6, width: 12, height: 12)), with: .color(OceanPalette.teal), lineWidth: 1.4)
            context.draw(Text("БАЗА").font(.system(size: 9, weight: .medium)).foregroundStyle(OceanPalette.teal), at: CGPoint(x: base.x, y: base.y - 16))
            context.fill(Path(roundedRect: CGRect(x: wreck.x - 5, y: wreck.y - 4, width: 10, height: 8), cornerRadius: 2), with: .color(engine.hasBlackBox ? OceanPalette.muted : OceanPalette.gold))
            context.draw(Text(engine.hasBlackBox ? "ASTER" : "ЯЩИК").font(.system(size: 9, weight: .medium)).foregroundStyle(OceanPalette.gold), at: CGPoint(x: wreck.x, y: wreck.y + 15))
            context.fill(Path(ellipseIn: CGRect(x: boat.x - 4, y: boat.y - 4, width: 8, height: 8)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: boat.x - 8, y: boat.y - 8, width: 16, height: 16)), with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        .accessibilityLabel("Карта сектора: база на северо-западе, корабль на юго-востоке. Между рифами есть западный обход и центральный путь через мины.")
    }
}

private struct DiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .bold)).foregroundStyle(OceanPalette.ink)
            .padding(.horizontal, 20).frame(height: 56)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.83, blue: 0.46), OceanPalette.gold], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: OceanPalette.gold.opacity(0.1), radius: 16, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
