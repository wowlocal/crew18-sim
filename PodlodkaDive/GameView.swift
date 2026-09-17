import SwiftUI
import UIKit
import Combine

struct GameView: View {
    @StateObject private var engine: GameEngine
    @StateObject private var recorder: BlackBoxRecorder
    @StateObject private var captain = CaptainNote()
    @State private var showingBlackBox = false
    @State private var showingArchives = false
    @StateObject private var announcer: VoiceOverAnnouncer
    @AccessibilityFocusState private var focusedControl: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage("podlodkaDive.voiceOverButtons") private var voiceOverButtons = false
    @State private var showingCampaign = false
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var confirmingAbandon = false
    @State private var showingMap = false
    @State private var showingCrewJournal = false
    @State private var crewVisibleLimit = 50
    @AppStorage("podlodkaDive.nightExpedition") private var nightExpedition = false
    @State private var showingGarage = false
    @State private var showingJournal = false
    @State private var showingReplay = false
    @State private var showingBureau = false
    @State private var showingCaptainJournal = false
    @State private var pendingStyle: SubmarineStyle?
    @State private var garageMessage = ""

    init(engine: GameEngine = GameEngine()) {
        let arguments = ProcessInfo.processInfo.arguments
        _engine = StateObject(wrappedValue: engine)
        _recorder = StateObject(wrappedValue: BlackBoxRecorder(engine: engine))
        _showingMap = State(initialValue: arguments.contains("map"))
        _announcer = StateObject(wrappedValue: VoiceOverAnnouncer(engine: engine))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameCanvas(engine: engine, nightExpedition: nightExpedition).accessibilityHidden(true)
                if nightExpedition, engine.state != .ready {
                    Color.black.opacity(0.84)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if engine.state == .ready {
                    ScrollView {
                        welcome(size: proxy.size, insets: proxy.safeAreaInsets)
                            .frame(minHeight: proxy.size.height)
                    }
                } else {
                    if engine.state == .playing {
                        if dynamicTypeSize.isAccessibilitySize {
                            largeTextInstruments(insets: proxy.safeAreaInsets)
                        } else {
                            instruments(insets: proxy.safeAreaInsets)
                            controls(insets: proxy.safeAreaInsets)
                        }
                    }
                    if engine.state != .playing {
                        OceanPalette.ink.opacity(0.78).ignoresSafeArea()
                        if showingMap {
                            ScrollView {
                                mapPanel(height: proxy.size.height)
                                    .padding(.vertical, max(proxy.safeAreaInsets.top, 48))
                            }
                        } else {
                            ScrollView {
                                resultPanel.padding(.vertical, max(proxy.safeAreaInsets.top, 48))
                                    .frame(minHeight: proxy.size.height)
                            }
                        }
                    }
                }
            }
            .onAppear {
                engine.resize(to: proxy.size)
#if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let marker = arguments.firstIndex(of: "-accessibilityAuditState"), arguments.indices.contains(marker + 1) {
                    engine.prepareAccessibilityAuditState(arguments[marker + 1])
                }
#endif
                if engine.state != .ready { engine.startLoop() }
            }
            .onDisappear { engine.stopLoop() }
            .onChange(of: proxy.size) { _, size in engine.resize(to: size) }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .tint(OceanPalette.teal)
        .onChange(of: dynamicTypeSize) { _, _ in engine.setSteering(.zero) }
        .onChange(of: voiceOverEnabled) { _, _ in engine.setSteering(.zero) }
        .onChange(of: voiceOverButtons) { _, _ in engine.setSteering(.zero) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                captain.finish(recorder: recorder)
                engine.pause()
                engine.captainLogger.flush()
                let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Expedition flush")
                Task {
                    await engine.flushJournal()
                    await recorder.drain()
                    if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
                }
            }
        }
        .onChange(of: showingMap) { _, visible in engine.navigate(to: visible ? "Map" : (engine.state == .playing ? "Game" : "Pause"), reason: visible ? "openMap" : "closeMap") }
        .sensoryFeedback(.selection, trigger: engine.pickupCount)
        .sensoryFeedback(.error, trigger: engine.damageCount)
        .sensoryFeedback(.warning, trigger: engine.eventCount)
        .sensoryFeedback(.success, trigger: engine.state == .completed)
        .preferredColorScheme(.dark)
        .task(id: "\(engine.state)-\(showingMap)") {
            let destination: String?
            switch engine.state {
            case .ready: destination = "startDive"
            case .playing: destination = "steeringPad"
            case .paused: destination = showingMap ? "closeMap" : "resumeDive"
            case .completed, .gameOver: destination = "retryDive"
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            focusedControl = destination
            if showingMap { announcer.describeMap() }
        }
        .onChange(of: showingGarage) { _, visible in engine.navigate(to: visible ? "Garage" : "Welcome", reason: visible ? "openGarage" : "closeGarage") }
        .onChange(of: showingJournal) { _, visible in engine.navigate(to: visible ? "Journal" : journalReturnScreen, reason: visible ? "openJournal" : "closeJournal") }
        .onChange(of: showingReplay) { _, visible in engine.navigate(to: visible ? "Replay" : journalReturnScreen, reason: visible ? "openReplay" : "closeReplay") }
        .onChange(of: showingCampaign) { _, visible in
            engine.navigate(to: visible ? "Campaign" : "Welcome", reason: visible ? "openCampaign" : "closeCampaign")
            recorder.flow(visible ? "campaign" : "ready")
        }
        .sheet(isPresented: $showingSettings) { settingsPanel }
        .sheet(isPresented: $showingHelp) { helpPanel }
        .fullScreenCover(isPresented: $showingCampaign) { CampaignView(engine: engine) }
        .alert("Прервать рейс?", isPresented: $confirmingAbandon) {
            Button("Прервать рейс", role: .destructive) { showingMap = false; engine.returnToMenu() }
                .accessibilityIdentifier("confirmAbandon")
            Button("Остаться", role: .cancel) {}.accessibilityIdentifier("cancelAbandon")
        } message: {
            Text("Недоставленная добыча пропадёт. Кристаллы сохранятся.")
        }
        .fullScreenCover(isPresented: $showingArchives) { archiveLibrary }
        .sheet(isPresented: $showingGarage) { garagePanel }
        .sheet(isPresented: $showingReplay) {
            if let id = engine.expeditionId {
                NavigationStack {
                    ExpeditionReplayView(expeditionId: id)
                        .toolbar { Button("Закрыть") { showingReplay = false } }
                }
            }
        }
        .onChange(of: showingMap) { _, value in recorder.flow(value ? "map" : String(describing: engine.state)) }
        .onChange(of: showingGarage) { _, value in recorder.flow(value ? "garage" : "ready") }
        .onChange(of: showingBlackBox) { _, value in recorder.flow(value ? "journal" : String(describing: engine.state)) }
        .onChange(of: engine.state) { _, state in
            if state == .ready { engine.stopLoop() } else { engine.startLoop() }
            if state != .playing { captain.finish(recorder: recorder) }
        }

    }

    private var journalReturnScreen: String {
        switch engine.state {
        case .ready: "Welcome"
        case .playing: "Game"
        case .paused: showingMap ? "Map" : "Pause"
        case .completed, .gameOver: "Result"
        }
    }

    private var voiceNoteControls: some View {
        VStack {
            if captain.recording { Text(captain.text).font(.body).lineLimit(3) }
            if let error = captain.error { Text(error).font(.body) }
            Button { Task { await captain.toggle(recorder: recorder) } } label: {
                Label(captain.recording ? "Закончить заметку" : "Заметка капитана",
                      systemImage: captain.recording ? "stop.circle" : "mic")
            }
            .disabled(captain.busy).buttonStyle(.bordered).controlSize(.large)
            .tint(.white).background(.black, in: Capsule()).accessibilityIdentifier("captainNote")
        }.padding(.bottom, 8)
    }

    private var journalButton: some View {
        Button { showingArchives = true } label: {
            Label("Журналы экспедиции", systemImage: "books.vertical")
                .font(.body).foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(OceanPalette.ink, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("openJournal")
    }

    private var archiveLibrary: some View {
        NavigationStack {
            List {
                Button("Закрыть") { showingArchives = false }.font(.body).frame(minHeight: 44).accessibilityIdentifier("closeArchives")
                Button("События, реплей и граф") {
                    Task { await engine.flushJournal(); showingJournal = true }
                }.accessibilityIdentifier("openTelemetry")
                Button("Подводное бюро расследований") { showingBureau = true }
                    .accessibilityIdentifier("openBureau")
                Button("Вахтенный журнал") { showingCaptainJournal = true }
                    .accessibilityIdentifier("openCaptainJournal")
                Button("Чёрный ящик и заметки") {
                    Task { await recorder.drain(); showingBlackBox = true }
                }.accessibilityIdentifier("openBlackBox")
                Button("Реплики экипажа") { showingCrewJournal = true }
                    .accessibilityIdentifier("openCrewJournal")
            }
            .foregroundStyle(.primary)
            .navigationTitle("Журналы экспедиции")
        }
        .fullScreenCover(isPresented: $showingJournal) { ExpeditionJournalView() }
        .fullScreenCover(isPresented: $showingBureau) { BureauView(journal: .shared) }
        .fullScreenCover(isPresented: $showingCaptainJournal) { CaptainJournalView(logger: engine.captainLogger) }
        .fullScreenCover(isPresented: $showingBlackBox) { BlackBoxJournal() }
        .fullScreenCover(isPresented: $showingCrewJournal) { journalPanel }
    }

    private func largeTextInstruments(insets: EdgeInsets) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(engine.objectiveText).font(.title2).accessibilityAddTraits(.isHeader)
                Text(engine.missionStatus).font(.body)
                Text(engine.accessibilityStatus).font(.body)
                Text(engine.sectorOverview).font(.body)
                SteeringPad(onInput: engine.setSteering, steering: engine.steering,
                            contacts: engine.sonarContacts, onSummary: announcer.describeSurroundings)
                    .frame(height: 158).accessibilityFocused($focusedControl, equals: "steeringPad")
                Button("Что вокруг?", action: announcer.describeSurroundings)
                Button("Сонар", action: engine.activateSonar)
                    .disabled(!engine.canSonar).accessibilityIdentifier("sonar")
                Button("Форсаж", action: engine.activateBoost)
                    .disabled(!engine.canBoost).accessibilityIdentifier("boost")
                Button("Усилить фары", action: engine.activateLightBoost)
                    .disabled(!engine.canLightBoost).accessibilityIdentifier("lightBoost")
                if engine.zone == .ocean {
                    Button("Карта экспедиции", action: openMap).accessibilityIdentifier("openMap")
                }
                voiceNoteControls
                Button("Пауза", action: engine.pause).accessibilityIdentifier("pauseDive")
            }
            .buttonStyle(.bordered).controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24).padding(.top, max(insets.top, 48)).padding(.bottom, max(insets.bottom, 24))
        }
        .background(OceanPalette.ink)
    }

    private func welcome(size: CGSize, insets: EdgeInsets) -> some View {
        VStack(spacing: 24) {
            HStack {
                Text("PODLODKA / 18")
                    .font(.system(.headline, design: .monospaced)).foregroundStyle(.white)
                Spacer()
                Menu {
                    Button("Гараж", systemImage: "wrench.and.screwdriver") {
                        garageMessage = ""
                        showingGarage = true
                    }.accessibilityIdentifier("openGarage")
                    Button("Журналы экспедиции", systemImage: "books.vertical") {
                        showingArchives = true
                    }.accessibilityIdentifier("openJournal")
                    Button("Настройки", systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }.accessibilityIdentifier("openSettings")
                } label: {
                    Image(systemName: "ellipsis").font(.title2)
                        .frame(width: 44, height: 44).background(OceanPalette.ink, in: Circle())
                }
                .foregroundStyle(.white).accessibilityLabel("Меню")
                .accessibilityIdentifier("surfaceMenu")
            }
            Text("Курс на глубину")
                .font(.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(.white).accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: size.height * 0.22)
            VStack(alignment: .leading, spacing: 12) {
                Button { showingCampaign = true } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Экспедиция \(engine.mission?.number ?? 1) из 3")
                                .font(.subheadline).foregroundStyle(OceanPalette.teal)
                            Text(engine.mission?.title ?? "Затонувший «Астер»")
                                .font(.title2.bold()).foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .padding(18).background(OceanPalette.ink, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain).disabled(!engine.isCampaign)
                .accessibilityIdentifier("openCampaign")
                .accessibilityHint("Выбрать другую экспедицию и прочитать задание")
                Button {
                    showingMap = false
                    engine.startGame()
                } label: {
                    HStack { Spacer(); Text("Начать"); Spacer(); Image(systemName: "arrow.right") }
                }
                .buttonStyle(DiveButtonStyle()).accessibilityLabel("Начать экспедицию")
                .accessibilityIdentifier("startDive").accessibilityFocused($focusedControl, equals: "startDive")
                Button("Как играть") { showingHelp = true }
                    .font(.body).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("openHelp")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, max(insets.top, 48) + 12)
        .padding(.bottom, max(insets.bottom, 20) + 12)
        .frame(minHeight: size.height)
        .background(LinearGradient(colors: [OceanPalette.ink, .clear, OceanPalette.ink],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Toggle("Ночная экспедиция", isOn: $nightExpedition)
                    .accessibilityHint("Затемняет океан и выключает фонарь. Управление не меняется.")
                Toggle("Пошаговое управление VoiceOver", isOn: $voiceOverButtons)
            }
            .navigationTitle("Настройки")
            .toolbar {
                Button { showingSettings = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Готово")
            }
        }
    }

    private var helpPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(engine.mission?.briefing ?? "Найди чёрный ящик и вернись на базу.")
                    Text(engine.mission?.hint ?? "Сохрани заряд на возвращение.")
                    Text("Управление").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Тяни стик в нужную сторону. Отпусти, чтобы остановить тягу. Течение продолжит нести лодку.")
                    Text("Сонар бесплатно обнаруживает находки. Форсаж расходует 7 энергии, усиление фар — 5.")
                    Text("Карта ставит игру на паузу. В меню паузы доступны журналы, заметка капитана и курс на базу.")
                    Text("С VoiceOver используй действия на руле. Пошаговое управление включается в настройках.")
                }.font(.body).foregroundStyle(.white).padding(24)
            }
            .background(OceanPalette.ink).navigationTitle("Как играть")
            .toolbar {
                Button { showingHelp = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Готово")
            }
        }
    }

    private var garagePanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Подлодка на прокачку").font(.title.bold()).accessibilityAddTraits(.isHeader)
                    Text("Баланс: \(engine.crystals) кристаллов").font(.body)
                    Text("Собирай ромбовидные кристаллы в океане: каждая находка даёт 10. Они сохраняются сразу, даже при поражении. Стили покупаются навсегда и меняют только внешность.")
                    Text("Установлено: \(engine.selectedStyle.title). \(engine.selectedStyle.description)")
                    ForEach(SubmarineStyle.allCases) { style in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(style.title).font(.body).accessibilityAddTraits(.isHeader)
                            Text(style.description)
                            Text(engine.selectedStyle == style ? "Выбрано" : (engine.owns(style) ? "Куплено" : "Цена: \(style.price) кристаллов"))
                            if !engine.owns(style), engine.crystals < style.price {
                                Text("Не хватает \(style.price - engine.crystals) кристаллов")
                            }
                            Button {
                                if engine.owns(style) { applyStyle(style) }
                                else { pendingStyle = style }
                            } label: {
                                Text(engine.selectedStyle == style ? "Установлено" : (engine.owns(style) ? "Установить" : "Купить за \(style.price) кристаллов"))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(engine.selectedStyle == style || (!engine.owns(style) && engine.crystals < style.price))
                            .accessibilityLabel("\(style.title): \(engine.owns(style) ? "установить" : "купить за \(style.price) кристаллов")")
                            .accessibilityValue(engine.selectedStyle == style ? "Выбрано" : (engine.owns(style) ? "Куплено" : "Не куплено"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !garageMessage.isEmpty { Text(garageMessage).accessibilityIdentifier("garageResult") }
                }.padding()
            }
            .navigationTitle("Гараж")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingGarage = false } } }
            .alert("Купить стиль?", isPresented: Binding(get: { pendingStyle != nil }, set: { if !$0 { pendingStyle = nil } })) {
                if let style = pendingStyle {
                    Button("Купить за \(style.price) кристаллов") { applyStyle(style); pendingStyle = nil }
                    Button("Отмена", role: .cancel) { pendingStyle = nil }
                }
            } message: {
                if let style = pendingStyle { Text("\(style.title). \(style.description) Спишется \(style.price) кристаллов. Стиль будет установлен сразу.") }
            }
        }
    }

    private func applyStyle(_ style: SubmarineStyle) {
        recorder.record(.event, "garage.selection", attrs: ["style": style.rawValue, "balance": String(engine.crystals)])
        garageMessage = engine.customize(style)
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: garageMessage) }
    }

    private func instruments(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.zone == .bossCave ? "Спрут" : engine.targetLabel)
                        .font(.headline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.radians(atan2(engine.target.y - engine.position.y,
                                                          engine.target.x - engine.position.x) + .pi / 2))
                        Text(engine.zone == .bossCave
                             ? "\(Int(ceil(engine.bossTimeRemaining))) с"
                             : "\(engine.targetDistance) м")
                    }.font(.subheadline.monospacedDigit()).foregroundStyle(OceanPalette.gold)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .ignore).accessibilityIdentifier("missionObjective")
                .accessibilityLabel(engine.objectiveText)
                .accessibilityValue("\(engine.missionStatus). \(engine.targetDistance) метров, на \(engine.targetClockHour) часов")
                hudButton("ear", label: "Озвучить обстановку", id: "speakSurroundings", action: announcer.describeSurroundings)
                if engine.zone == .ocean {
                    hudButton("map", label: "Карта экспедиции", id: "openMap", action: openMap)
                }
                hudButton("pause.fill", label: "Пауза", id: "pauseDive", action: engine.pause)
            }
            HStack(spacing: 13) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(.body))
                    Text("\(Int(ceil(engine.energy)))%")
                        .font(.system(.body, design: .monospaced).weight(.semibold)).frame(minWidth: 35, alignment: .leading)

                }
                .foregroundStyle(engine.energy < 25 ? OceanPalette.danger : OceanPalette.teal)
                .frame(minHeight: 44).contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yL10n.text("a11y.energy.label", defaultValue: "Энергия"))
                .accessibilityValue(A11yL10n.format("a11y.percent.format", defaultValue: "%lld процентов", Int64(engine.energy)))
                .frame(minHeight: 44)
                .accessibilitySortPriority(7)
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Image(systemName: index < engine.hull ? "heart.fill" : "heart")
                            .font(.system(.body)).foregroundStyle(index < engine.hull ? OceanPalette.danger : OceanPalette.white.opacity(0.4))
                    }
                    if engine.hasShield { Image(systemName: "shield.fill").font(.system(.body)).foregroundStyle(OceanPalette.blue) }
                }
                .frame(minHeight: 44).contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yL10n.text("a11y.hull.label", defaultValue: "Корпус"))
                .accessibilityValue(hullAccessibilityValue)
                .frame(minHeight: 44)
                .accessibilitySortPriority(6)
                Spacer(minLength: 0)
                Label("\(engine.cargoValue)", systemImage: "shippingbox")
                    .font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(OceanPalette.gold)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11yL10n.text("a11y.cargo.label", defaultValue: "Груз на борту"))
                    .accessibilityValue("\(engine.cargoValue)")
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilitySortPriority(5)
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(OceanPalette.ink, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16).padding(.top, max(insets.top, 48) + 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func hudButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(.body).weight(.semibold))
                .foregroundStyle(OceanPalette.white).frame(width: 44, height: 44)
                .background(OceanPalette.ink.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(OceanPalette.teal.opacity(0.22), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private func openMap() {
        engine.logWatch("map", "Открыта карта экспедиции")
        engine.pauseForScreen("Map")
        showingMap = true
    }

    private func controls(insets: EdgeInsets) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if engine.noticeRemaining > 0 && engine.notice != engine.objectiveText {
                Text(engine.notice).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(12).frame(maxWidth: 320)
                    .background(OceanPalette.ink, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20).allowsHitTesting(false)
                    .accessibilityLabel(engine.notice)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if voiceOverEnabled && voiceOverButtons {
                    VoiceOverSteeringControls(onMove: engine.moveForVoiceOver)
                        .accessibilityFocused($focusedControl, equals: "steeringPad")
                        .frame(width: 154, height: 154)
                } else {
                    SteeringPad(onInput: engine.setSteering, steering: engine.steering,
                                contacts: engine.sonarContacts, onSummary: announcer.describeSurroundings)
                        .accessibilityFocused($focusedControl, equals: "steeringPad")
                        .frame(width: 154, height: 154).accessibilitySortPriority(3)
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    AbilityButton(icon: engine.isLightBoostActive ? "flashlight.on.fill" : "flashlight.off.fill",
                                  title: "Фары", progress: 1 - engine.lightBoostCooldown / GameEngine.lightBoostRecharge,
                                  enabled: engine.canLightBoost, color: OceanPalette.gold,
                                  accessibilityLabel: "Усилить свет фар",
                                  accessibilityValue: abilityValue(cooldown: engine.lightBoostCooldown),
                                  accessibilityHint: "Усиливает свет на четыре секунды и расходует 5 энергии.",
                                  action: engine.activateLightBoost).accessibilityIdentifier("lightBoost")
                    HStack(spacing: 12) {
                        AbilityButton(icon: "dot.radiowaves.left.and.right", title: "Сонар",
                                      progress: 1 - engine.sonarCooldown / 8, enabled: engine.canSonar,
                                      color: OceanPalette.teal, accessibilityLabel: "Сонар",
                                      accessibilityValue: abilityValue(cooldown: engine.sonarCooldown),
                                      accessibilityHint: "Бесплатно обнаруживает находки поблизости.",
                                      action: engine.activateSonar).accessibilityIdentifier("sonar")
                        AbilityButton(icon: "bolt.fill", title: "Форсаж",
                                      progress: 1 - engine.boostCooldown / 4.5, enabled: engine.canBoost,
                                      color: OceanPalette.gold, accessibilityLabel: "Форсаж",
                                      accessibilityValue: abilityValue(cooldown: engine.boostCooldown),
                                      accessibilityHint: "Рывок по выбранному курсу. Расходует 7 энергии.",
                                      action: engine.activateBoost).accessibilityIdentifier("boost")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, max(insets.bottom, 20))
        }
    }

    private func abilityValue(cooldown: TimeInterval) -> String {
        cooldown > 0
            ? A11yL10n.format("a11y.cooldown.format", defaultValue: "Перезарядка: %lld секунд", Int64(ceil(cooldown)))
            : A11yL10n.text("a11y.ready", defaultValue: "Готов")
    }

    private var hullAccessibilityValue: String {
        if engine.hasShield {
            return A11yL10n.format("a11y.hull.shield.format", defaultValue: "%lld из 3. Щит активен", Int64(engine.hull))
        }
        return A11yL10n.format("a11y.hull.format", defaultValue: "%lld из 3", Int64(engine.hull))
    }

    private func mapPanel(height: CGFloat) -> some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("КАРТА ЭКСПЕДИЦИИ").font(.system(.body, design: .monospaced).weight(.semibold)).tracking(0).foregroundStyle(OceanPalette.teal)
                    Text("Сектор «Aster»").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(OceanPalette.white)
                }
                Spacer()
                Text("ПАУЗА").font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(OceanPalette.white)
            }
            .accessibilityHidden(true)
            ExpeditionMap(engine: engine)
                .accessibilityHidden(true)
                .frame(height: min(395, height * 0.49))
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
                    if engine.portalRevealed { mapKey("circle.hexagongrid", "Портал", OceanPalette.portal) }
                }
            }
            .accessibilityHidden(true)
            Text("Сонар отмечает находки. Линия — пройденный путь.")
                .font(.system(.body).weight(.semibold)).foregroundStyle(OceanPalette.white).multilineTextAlignment(.center)
                .accessibilityHidden(true)
            ForEach(engine.sonarContacts) { contact in
                Text(A11yL10n.contact(contact)).font(.body.weight(.semibold)).foregroundStyle(OceanPalette.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                showingMap = false
                engine.togglePause()
            } label: {
                HStack { Spacer(); Text("Вернуться в океан"); Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(DiveButtonStyle()).accessibilityIdentifier("closeMap").accessibilityFocused($focusedControl, equals: "closeMap")
                .accessibilityLabel(A11yL10n.text("a11y.map.close", defaultValue: "Вернуться в океан"))
                .accessibilityHint(A11yL10n.text("a11y.map.close.hint", defaultValue: "Закрывает карту и продолжает экспедицию."))
        }
        .padding(22).frame(maxWidth: 380)
        .background(Color(red: 0.035, green: 0.15, blue: 0.20), in: RoundedRectangle(cornerRadius: 27))
        .overlay(RoundedRectangle(cornerRadius: 27).stroke(OceanPalette.teal.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private func mapKey(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(.body)).foregroundStyle(color)
    }

    private var journalPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button("Готово") { showingCrewJournal = false }.font(.body).frame(minHeight: 44)
                    Section {
                        Text("Последние 500 записей текущего запуска приложения. Реплики за бортом — выдержки из этого журнала.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    if engine.crewJournal.entries.isEmpty {
                        Text("Журнал пуст. Начните экспедицию.").font(.body)
                    }
                    ForEach(engine.crewJournal.entries.reversed().prefix(crewVisibleLimit)) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Экспедиция \(entry.expedition) · \(Int(entry.seconds)) с · \(entry.level.rawValue)")
                                .font(.body).foregroundStyle(.secondary)
                            Text(entry.message).font(.body)
                            if let phrase = entry.crewPhrase { Text(phrase).foregroundStyle(OceanPalette.teal) }
                            Text(entry.snapshot).font(.body)
                            Text(entry.date, style: .time).font(.body).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    if crewVisibleLimit < engine.crewJournal.entries.count {
                        Button("Ещё записи") { crewVisibleLimit += 50 }
                    }
                }.font(.body).padding(24)
            }
            .navigationTitle("Бортовой журнал")
        }
    }


    private var resultPanel: some View {
        let paused = engine.state == .paused
        let success = engine.state == .completed
        let title = paused ? "Можно выдохнуть." : (success
            ? (engine.outcome == .returned ? "Экипаж дома." : "Задание выполнено.") : "Океан сильнее.")
        let detail = paused ? "Экспедиция на паузе. Заряд сохраняется." : (success ? engine.resultDetail : (engine.failureReason == .energy ? "Заряд закончился. Груз остался на глубине." : "Корпус не выдержал. Груз остался на глубине."))
        return VStack(spacing: 22) {

            Image(systemName: paused ? "pause.fill" : (success ? "shippingbox.fill" : "water.waves"))
                .font(.system(.title).weight(.medium)).foregroundStyle(success ? OceanPalette.gold : OceanPalette.teal)
                .frame(width: 72, height: 72)
                .background(OceanPalette.teal.opacity(0.07), in: Circle())
                .overlay(Circle().stroke(OceanPalette.teal.opacity(0.15), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(paused ? "ТИХАЯ ВОДА" : (engine.isNewRecord ? "НОВЫЙ РЕКОРД ЭКСПЕДИЦИИ" : "ЭКСПЕДИЦИЯ ЗАВЕРШЕНА"))
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                    .font(.system(.body, design: .monospaced).weight(.semibold)).tracking(0).foregroundStyle(OceanPalette.teal)
                Text(title).font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.8)
                    .foregroundStyle(OceanPalette.white)
                Text(detail).font(.system(.body).weight(.semibold)).foregroundStyle(OceanPalette.white).fixedSize(horizontal: false, vertical: true).background(OceanPalette.ink).multilineTextAlignment(.center).lineSpacing(3)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(paused ? "pausedSummary" : (success ? "completedSummary" : "gameOverSummary"))
            .accessibilityLabel(resultAccessibilityTitle(paused: paused, success: success))
            .accessibilityValue(resultAccessibilityDetail(paused: paused, success: success))
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                resultStat(paused ? engine.cargoValue : engine.score, title: paused ? "ГРУЗ НА БОРТУ" : "ДОСТАВЛЕНО",
                           accessibilityTitle: paused
                               ? A11yL10n.text("a11y.cargo.label", defaultValue: "Груз на борту")
                               : A11yL10n.text("a11y.delivered", defaultValue: "Доставлено"), highlighted: true)
                Rectangle().fill(OceanPalette.teal.opacity(0.15)).frame(width: 1, height: 44)
                resultStat(engine.bestScore, title: "ЛУЧШАЯ ДОБЫЧА",
                           accessibilityTitle: A11yL10n.text("a11y.best.label", defaultValue: "Лучшая добыча"), highlighted: false)
            }
            .padding(.vertical, 16).background(OceanPalette.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 12) {
                journalButton
                if paused {
                    voiceNoteControls
                    Button("Как играть") { showingHelp = true }.frame(minHeight: 44)
                }
                if !paused {
                    Button { Task { await engine.flushJournal(); showingReplay = true } } label: {
                        Label("Реплей экспедиции", systemImage: "play.rectangle")
                            .font(.body.weight(.semibold)).foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(8).background(OceanPalette.ink, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("resultReplay")
                }
                if success, engine.outcome == .completed, let next = engine.mission?.next {
                    Button {
                        engine.returnToMenu()
                        _ = engine.selectMission(next)
                        showingCampaign = true
                    } label: {
                        Text("Следующая экспедиция").frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(DiveButtonStyle()).accessibilityIdentifier("nextMission")
                }
                Button {
                    if paused { engine.togglePause() } else { engine.startGame() }
                } label: {
                    HStack { Spacer(); Text(paused ? "Продолжить" : "Новая экспедиция"); Spacer(); Image(systemName: paused ? "play.fill" : "arrow.clockwise") }
                }.buttonStyle(DiveButtonStyle()).accessibilityIdentifier(paused ? "resumeDive" : "retryDive")
                    .accessibilityLabel(paused
                        ? A11yL10n.text("a11y.resume", defaultValue: "Продолжить")
                        : A11yL10n.text("a11y.retry", defaultValue: "Новая экспедиция"))
                    .accessibilityFocused($focusedControl, equals: paused ? "resumeDive" : "retryDive")
                if paused, engine.isCampaign, !engine.objectiveReady {
                    if engine.zone == .ocean {
                        Text("Вернись в круг базы и остановись. Добыча сохранится, следующее задание не откроется.")
                            .font(.body).foregroundStyle(.white).background(OceanPalette.ink)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                        Button(engine.missionRun?.returningEarly == true ? "Продолжить задание" : "Курс на базу") {
                            let requested = engine.missionRun?.returningEarly != true
                            engine.togglePause()
                            engine.setReturnToBase(requested)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .buttonStyle(.bordered).accessibilityIdentifier("returnCourse")
                    } else {
                        Text("Выйди из пещеры, чтобы проложить курс домой.").font(.body)
                    }
                }
                if paused {
                    Button(action: openMap) {
                        Text("Открыть карту").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                        .font(.system(.body).weight(.semibold)).foregroundStyle(OceanPalette.teal)
                        .accessibilityLabel(A11yL10n.text("a11y.map.open", defaultValue: "Карта экспедиции"))
                }
                Button {
                    if paused { confirmingAbandon = true }
                    else { showingMap = false; engine.returnToMenu(); showingCampaign = engine.isCampaign }
                } label: {
                    Text(paused ? "Прервать рейс" : "Выбор экспедиции").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                    .font(.system(.body).weight(.semibold)).foregroundStyle(OceanPalette.white)
                    .accessibilityIdentifier("returnToMenu")
                    .accessibilityLabel(paused ? "Прервать рейс" : "Выбор экспедиции")
            }
            if !paused, let diveID = engine.diveID {
                LatestReceiptView(journal: .shared, diveID: diveID)
            }
        }
        .padding(25).frame(maxWidth: 360)
        .background(Color(red: 0.035, green: 0.15, blue: 0.20), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(OceanPalette.teal.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 25)
    }

    private func resultAccessibilityTitle(paused: Bool, success: Bool) -> String {
        if paused { return A11yL10n.text("a11y.result.paused", defaultValue: "Экспедиция на паузе") }
        if success { return engine.outcome == .returned ? "Вернулись без выполнения задания" : "Задание выполнено" }
        return A11yL10n.text("a11y.result.failure", defaultValue: "Экспедиция завершена")
    }

    private func resultAccessibilityDetail(paused: Bool, success: Bool) -> String {
        if paused { return A11yL10n.text("a11y.result.paused.detail", defaultValue: "Заряд сохраняется.") }
        if success { return engine.resultDetail }
        if engine.failureReason == .energy {
            return A11yL10n.text("a11y.result.energy.detail", defaultValue: "Заряд закончился. Груз остался на глубине.")
        }
        return A11yL10n.text("a11y.result.hull.detail", defaultValue: "Корпус не выдержал. Груз остался на глубине.")
    }

    private func resultStat(_ value: Int, title: String, accessibilityTitle: String, highlighted: Bool) -> some View {
        VStack(spacing: 6) {
            Text("\(value)").font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(highlighted ? OceanPalette.white : OceanPalette.gold)
            Text(title).font(.system(.body, design: .monospaced).weight(.semibold)).fixedSize(horizontal: false, vertical: true).tracking(0).foregroundStyle(OceanPalette.white)
        }.frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue("\(value)")
    }
}

/// VoiceOver exposes discrete, immediate commands instead of requiring a drag.
/// Every tap produces a short steering pulse; speech never gates the action.
private struct VoiceOverSteeringControls: View {
    let onMove: (CGVector) -> Void

    var body: some View {
        VStack(spacing: 3) {
            directionButton("ВВЕРХ", spokenLabel: "Двигаться вверх", icon: "arrow.up", id: "moveUp",
                            vector: CGVector(dx: 0, dy: -1))
            HStack(spacing: 38) {
                directionButton("ВЛЕВО", spokenLabel: "Двигаться влево", icon: "arrow.left", id: "moveLeft",
                                vector: CGVector(dx: -1, dy: 0))
                directionButton("ВПРАВО", spokenLabel: "Двигаться вправо", icon: "arrow.right", id: "moveRight",
                                vector: CGVector(dx: 1, dy: 0))
            }
            directionButton("ВНИЗ", spokenLabel: "Двигаться вниз", icon: "arrow.down", id: "moveDown",
                            vector: CGVector(dx: 0, dy: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Управление подлодкой")
    }

    private func directionButton(_ title: String, spokenLabel: String, icon: String,
                                 id: String, vector: CGVector) -> some View {
        Button { onMove(vector) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(.body).weight(.bold))
                Text(title).font(.system(.body, design: .monospaced).weight(.bold))
            }
            .foregroundStyle(OceanPalette.teal)
            .frame(minWidth: 70, minHeight: 48)
            .background(OceanPalette.ink.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OceanPalette.teal.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Короткое перемещение через тягу подлодки")
        .accessibilityIdentifier(id)
    }
}

/// A native touch surface keeps ownership of the steering finger while the
/// other thumb presses an ability, and handles cancellation explicitly.
private struct SteeringPad: UIViewRepresentable {
    let onInput: (CGVector) -> Void
    let steering: CGVector
    let contacts: [AccessibilityContact]
    let onSummary: () -> Void

    func makeUIView(context: Context) -> SteeringSurface {
        let view = SteeringSurface()
        view.onSummary = onSummary
        view.onInput = onInput
        view.updateAccessibility(steering: steering, contacts: contacts)
        return view
    }

    func updateUIView(_ view: SteeringSurface, context: Context) {
        view.onInput = onInput
        view.onSummary = onSummary
        view.updateAccessibility(steering: steering, contacts: contacts)
    }
    static func dismantleUIView(_ view: SteeringSurface, coordinator: ()) {
        view.onInput = nil
        view.releaseInput()
    }
}

final class SteeringSurface: UIView {
    var onInput: ((CGVector) -> Void)?
    var onSummary: (() -> Void)?
    private var course: CompassCourse = .n
    private var finger: UITouch?
    private var origin: CGPoint?
    private var knob = CGVector.zero
    private var contacts: [AccessibilityContact] = []
    private var rotorIndex: Int?
    private var actualSteering = CGVector.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = A11yL10n.text("a11y.steering.label", defaultValue: "Руль подлодки")
        accessibilityHint = A11yL10n.text("a11y.steering.hint", defaultValue: "Смахните вверх или вниз для выбора курса, затем выполните действие Плыть. Смена выбранного курса не меняет тягу до команды Плыть. Стоп выключает тягу, но течение может сносить лодку.")
        accessibilityTraits = [.adjustable]
        accessibilityIdentifier = "steeringPad"
        accessibilityCustomActions = [
            action("a11y.sail", "Плыть", #selector(sail)),
            action("a11y.surroundings", "Что вокруг?", #selector(describeWorld)),
            action("a11y.direction.north", "Север", #selector(steerNorth)),
            action("a11y.direction.northeast", "Северо-восток", #selector(steerNorthEast)),
            action("a11y.direction.east", "Восток", #selector(steerEast)),
            action("a11y.direction.southeast", "Юго-восток", #selector(steerSouthEast)),
            action("a11y.direction.south", "Юг", #selector(steerSouth)),
            action("a11y.direction.southwest", "Юго-запад", #selector(steerSouthWest)),
            action("a11y.direction.west", "Запад", #selector(steerWest)),
            action("a11y.direction.northwest", "Северо-запад", #selector(steerNorthWest)),
            action("a11y.direction.stop", "Стоп, зависнуть", #selector(stop))
        ]
        accessibilityCustomRotors = [UIAccessibilityCustomRotor(
            name: A11yL10n.text("a11y.rotor.contacts", defaultValue: "Контакты сонара")
        ) { [weak self] predicate in
            guard let self, !self.contacts.isEmpty else { return nil }
            let step = predicate.searchDirection == .next ? 1 : -1
            let current = self.rotorIndex ?? (step > 0 ? -1 : self.contacts.count)
            let next = (current + step + self.contacts.count) % self.contacts.count
            self.rotorIndex = next
            self.accessibilityValue = A11yL10n.contact(self.contacts[next])
            return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: nil)
        }]
    }

    override func accessibilityIncrement() { changeCourse(1) }
    override func accessibilityDecrement() { changeCourse(-1) }
    private func changeCourse(_ offset: Int) {
        course = CompassCourse(rawValue: (course.rawValue + offset + 8) % 8)!
        rotorIndex = nil
        updateAccessibility(steering: actualSteering, contacts: contacts)
    }
    @objc private func sail() -> Bool { steer(course.vector) }
    @objc private func describeWorld() -> Bool { onSummary?(); return true }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func action(_ key: StaticString, _ fallback: String.LocalizationValue, _ selector: Selector) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: A11yL10n.text(key, defaultValue: fallback), target: self, selector: selector)
    }

    func updateAccessibility(steering: CGVector, contacts: [AccessibilityContact]) {
        self.contacts = contacts
        actualSteering = steering
        if let rotorIndex, rotorIndex >= contacts.count { self.rotorIndex = nil }
        if let rotorIndex {
            accessibilityValue = A11yL10n.contact(contacts[rotorIndex])
            return
        }
        let strength = hypot(steering.dx, steering.dy)
        let actualCourse = courseName(for: steering)
        accessibilityValue = A11yL10n.format("a11y.steering.value.format", defaultValue: "Курс: %@, тяга %lld процентов",
                                             actualCourse, Int64((strength * 100).rounded()))
            + ". " + A11yL10n.format("a11y.selected.course", defaultValue: "Выбран курс: %@", course.label)
    }

    private func courseName(for vector: CGVector) -> String {
        guard hypot(vector.dx, vector.dy) >= 0.08 else {
            return A11yL10n.text("a11y.course.stop", defaultValue: "стоп")
        }
        let sector = Int((atan2(vector.dy, vector.dx) / (.pi / 4)).rounded())
        switch sector {
        case 0: return A11yL10n.text("a11y.course.east", defaultValue: "восток")
        case 1: return A11yL10n.text("a11y.course.southeast", defaultValue: "юго-восток")
        case 2: return A11yL10n.text("a11y.course.south", defaultValue: "юг")
        case 3: return A11yL10n.text("a11y.course.southwest", defaultValue: "юго-запад")
        case 4, -4: return A11yL10n.text("a11y.course.west", defaultValue: "запад")
        case -3: return A11yL10n.text("a11y.course.northwest", defaultValue: "северо-запад")
        case -2: return A11yL10n.text("a11y.course.north", defaultValue: "север")
        default: return A11yL10n.text("a11y.course.northeast", defaultValue: "северо-восток")
        }
    }

    private func steer(_ vector: CGVector) -> Bool {
        rotorIndex = nil
        if hypot(vector.dx, vector.dy) > 0.08 { course = CompassCourse(vector: vector) }
        knob = CGVector(dx: vector.dx * 44, dy: vector.dy * 44)
        onInput?(vector)
        updateAccessibility(steering: vector, contacts: contacts)
        setNeedsDisplay()
        return true
    }

    @objc private func steerNorth() -> Bool { steer(CGVector(dx: 0, dy: -1)) }
    @objc private func steerNorthEast() -> Bool { steer(CGVector(dx: 0.707, dy: -0.707)) }
    @objc private func steerEast() -> Bool { steer(CGVector(dx: 1, dy: 0)) }
    @objc private func steerSouthEast() -> Bool { steer(CGVector(dx: 0.707, dy: 0.707)) }
    @objc private func steerSouth() -> Bool { steer(CGVector(dx: 0, dy: 1)) }
    @objc private func steerSouthWest() -> Bool { steer(CGVector(dx: -0.707, dy: 0.707)) }
    @objc private func steerWest() -> Bool { steer(CGVector(dx: -1, dy: 0)) }
    @objc private func steerNorthWest() -> Bool { steer(CGVector(dx: -0.707, dy: -0.707)) }
    @objc private func stop() -> Bool { steer(.zero) }

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
        rotorIndex = nil
        finger = nil
        origin = nil
        knob = .zero
        onInput?(.zero)
        updateAccessibility(steering: .zero, contacts: contacts)
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
    let progress: Double
    let enabled: Bool
    let color: Color
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String
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
                    Image(systemName: icon).font(.system(.title3).weight(.medium)).foregroundStyle(color.opacity(enabled ? 1 : 0.4))
                }.frame(width: 55, height: 55)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 3).background(OceanPalette.ink)
            }.frame(minWidth: 64)
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilitySortPriority(2)
    }
}

struct LiveExpeditionMap: View {
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
                let arrow = abs(zone.velocity.dx) > abs(zone.velocity.dy)
                    ? (zone.velocity.dx > 0 ? "→" : "←") : (zone.velocity.dy > 0 ? "↓" : "↑")
                context.draw(Text(arrow).font(.title).foregroundStyle(OceanPalette.blue), at: CGPoint(x: rect.midX, y: rect.midY))
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
            if let portal = engine.portal, engine.portalRevealed {
                let p = point(portal.position)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                               with: .color(OceanPalette.portal), lineWidth: 2)
            }
            let base = point(engine.level.base), boat = point(engine.position)
            context.stroke(Path(ellipseIn: CGRect(x: base.x - 6, y: base.y - 6, width: 12, height: 12)), with: .color(OceanPalette.teal), lineWidth: 1.4)
            context.draw(Text(A11yL10n.contactKind(.base)).font(.system(.body).weight(.semibold)).foregroundStyle(OceanPalette.teal), at: CGPoint(x: base.x, y: base.y - 16))
            for landmark in engine.missionLandmarks {
                let p = point(landmark.position)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(OceanPalette.gold), lineWidth: 2)
                context.draw(Text(landmark.label).font(.body).foregroundStyle(.white), at: CGPoint(x: p.x, y: p.y + 17))
            }
            context.fill(Path(ellipseIn: CGRect(x: boat.x - 4, y: boat.y - 4, width: 8, height: 8)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: boat.x - 8, y: boat.y - 8, width: 16, height: 16)), with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        .accessibilityLabel(engine.sectorOverview)
    }
}

private struct DiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body).weight(.bold)).foregroundStyle(Color.black)
            .padding(.horizontal, 20).padding(.vertical, 16).frame(minHeight: 56)
            .background(OceanPalette.gold, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: OceanPalette.gold.opacity(0.1), radius: 16, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
