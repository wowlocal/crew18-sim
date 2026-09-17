import Combine
import SwiftUI
import UIKit

/// Speech consumes simulation events; it never blocks steering or the fixed physics step.
@MainActor
final class VoiceOverAnnouncer: ObservableObject {
    enum Priority: Int { case beacon, event, danger }
    private struct Message {
        let key: String
        let text: String
        let priority: Priority
    }
    private var subscriptions = Set<AnyCancellable>()
    private var pending: [Message] = []
    private var delivery: Task<Void, Never>?
    private var beacon: SituationSummary?
    private var lastBeacon = -Double.infinity
    private var lastDanger = -Double.infinity
    private var seen: [String: TimeInterval] = [:]
    private var proximity: (id: String, level: Int)?
    private weak var engine: GameEngine?
    private let voiceOverRunning: () -> Bool
    private let post: (NSAttributedString) -> Void
    private let now: () -> TimeInterval

    init(engine: GameEngine,
         voiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         post: @escaping (NSAttributedString) -> Void = {
             UIAccessibility.post(notification: .announcement, argument: $0)
         }) {
        self.engine = engine
        self.voiceOverRunning = voiceOverRunning
        self.now = now
        self.post = post
        engine.events.sink { [weak self] event in self?.receive(event) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reset() }.store(in: &subscriptions)
    }

    private func reset() {
        delivery?.cancel()
        delivery = nil
        pending.removeAll()
        seen.removeAll()
        beacon = nil
        proximity = nil
        lastBeacon = -.infinity
        lastDanger = -.infinity
    }

    private func receive(_ event: GameEvent) {
        guard voiceOverRunning() else {
            reset()
            return
        }
        switch event {
        case .diagnostic: break
        case .danger(let text): enqueue(key: "danger", text: text, priority: .danger)
        case .speak(let text): enqueue(key: "speech:\(text)", text: text, priority: .event)
        case .energyLow:
            enqueue(key: "energy", text: A11yL10n.text("event.energy.low", defaultValue: "Внимание. Энергия ниже 25 процентов."), priority: .danger)
        case .objectiveChanged:
            // The same transition includes the localized black-box pickup event.
            break
        case .success, .record:
            // Completion is spoken as one summary after score and record have been stored.
            break
        case .stateChanged(let state):
            reset()
            let text: String
            switch state {
            case .ready: return
            case .playing:
                text = A11yL10n.text("speech.playing", defaultValue: "Экспедиция продолжается")
            case .paused:
                text = A11yL10n.text("speech.paused", defaultValue: "Пауза")
            case .completed:
                guard let engine else { return }
                text = A11yL10n.format("speech.completed", defaultValue: "Груз доставлен: %lld. Рекорд: %lld.", Int64(engine.score), Int64(engine.bestScore))
            case .gameOver:
                text = engine?.failureReason == .energy
                    ? A11yL10n.text("a11y.result.energy.detail", defaultValue: "Заряд закончился. Груз остался на глубине.")
                    : A11yL10n.text("a11y.result.hull.detail", defaultValue: "Корпус не выдержал. Груз остался на глубине.")
            }
            enqueue(key: "state", text: text, priority: .event)
        case .situation(let summary):
            warnAboutApproach(summary.danger)
            let time = now()
            guard time - lastBeacon >= 5, time - lastDanger >= 2 else { return }
            if let old = beacon {
                guard abs(old.targetDistance - summary.targetDistance) >= 20
                        || old.targetCourse != summary.targetCourse || old.returning != summary.returning
                        || old.danger?.id != summary.danger?.id || old.find?.id != summary.find?.id
                        || old.currentCourse != summary.currentCourse
                        || old.caveTimeRemaining == nil && summary.caveTimeRemaining != nil
                        || old.caveTimeRemaining != nil && summary.caveTimeRemaining == nil else { return }
            }
            beacon = summary
            lastBeacon = time
            enqueue(key: "beacon", text: Self.format(summary), priority: .beacon)
        }
    }

    private func warnAboutApproach(_ contact: SituationSummary.Contact?) {
        guard let contact else { proximity = nil; return }
        let level = contact.distance <= 8 ? 3 : contact.distance <= 16 ? 2 : contact.distance <= 30 ? 1 : 0
        let previous = proximity
        proximity = (contact.id, level)
        guard level > 0, previous?.id != contact.id || level > (previous?.level ?? 0) else { return }
        let text = A11yL10n.format("speech.danger", defaultValue: "Опасность. %@, %lld метров, %@.", contact.name, Int64(contact.distance), contact.course.label)
        enqueue(key: "approach", text: text, priority: .danger)
    }

    func describeSurroundings() {
        guard voiceOverRunning(), let engine, engine.state == .playing else { return }
        deliver(Self.format(engine.situationSummary), queued: false)
    }

    func describeMap() {
        guard voiceOverRunning(), let engine, engine.state == .paused else { return }
        deliver(engine.sectorOverview, queued: false)
    }

    private func enqueue(key: String, text: String, priority: Priority) {
        let time = now()
        // Actual danger events are edges from the engine: a second mine must speak again.
        if priority != .danger {
            seen = seen.filter { time - $0.value < 2 }
            guard seen[key] == nil else { return }
            seen[key] = time
        } else {
            lastDanger = time
            pending.removeAll { $0.priority == .beacon }
            delivery?.cancel()
            delivery = nil
        }
        pending.removeAll { $0.key == key }
        pending.append(Message(key: key, text: text, priority: priority))
        drain()
    }

    private func deliver(_ text: String, queued: Bool) {
        let speech = NSMutableAttributedString(string: text)
        speech.addAttribute(.accessibilitySpeechQueueAnnouncement, value: queued,
                            range: NSRange(location: 0, length: speech.length))
        post(speech)
    }

    private func drain() {
        guard delivery == nil, !pending.isEmpty, voiceOverRunning() else { return }
        let priority = pending.map(\.priority.rawValue).max()!
        let index = pending.firstIndex { $0.priority.rawValue == priority }!
        let message = pending.remove(at: index)
        deliver(message.text, queued: message.priority != .danger)
        delivery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            delivery = nil
            drain()
        }
    }

    static func format(_ summary: SituationSummary) -> String {
        var parts: [String]
        if let remaining = summary.caveTimeRemaining {
            parts = [A11yL10n.format("speech.cave", defaultValue: "Пещера спрута. Продержись ещё %lld секунд.", Int64(remaining))]
        } else {
            parts = [A11yL10n.format("speech.instruments", defaultValue: "Глубина %lld метров, скорость %lld метров в секунду.", Int64(summary.depth), Int64(summary.speed)),
                     A11yL10n.format("speech.target", defaultValue: "%@: %lld метров, %@.",
                                    summary.returning ? A11yL10n.contactKind(.base) : A11yL10n.pickupName(.blackBox),
                                    Int64(summary.targetDistance), summary.targetCourse.label)]
        }
        for contact in [summary.danger, summary.find].compactMap({ $0 }) {
            parts.append(A11yL10n.format("speech.contact", defaultValue: "%@: %lld метров, %@.", contact.name, Int64(contact.distance), contact.course.label))
        }
        if let course = summary.currentCourse {
            parts.append(A11yL10n.format("speech.current", defaultValue: "Течение: %@, %lld метров в секунду.", course.label, Int64(summary.currentSpeed)))
        }
        return parts.joined(separator: " ")
    }
}
