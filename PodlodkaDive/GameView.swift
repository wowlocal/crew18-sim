import SwiftUI

struct GameView: View {
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
            .onChange(of: proxy.size) { _, newSize in
                engine.resize(to: newSize)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.increase, trigger: engine.score)
        .sensoryFeedback(.error, trigger: engine.state == .gameOver)
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
                .contentTransition(.numericText())
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
                .contentTransition(.symbolEffect(.replace))
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
                .contentTransition(.numericText())
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
