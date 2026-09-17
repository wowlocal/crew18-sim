import SwiftUI
import UserNotifications

struct ReturnRoute: Equatable {
    let id: UUID
    var url: URL { URL(string: "podlodkadive://expedition/\(id.uuidString)")! }
    init(id: UUID) { self.id = id }
    init?(url: URL) {
        guard url.scheme?.lowercased() == "podlodkadive", url.host == "expedition",
              url.pathComponents.count == 2, url.query == nil, url.fragment == nil,
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        self.id = id
    }
}

struct ReturnEvent: Codable, Identifiable {
    let id: UUID
    let expedition: UUID?
    let date: Date
    let kind: String
    let title: String
    let text: String
    var sourceEventID: UUID? = nil
    var read = false
    var isNotification: Bool { kind.hasPrefix("push") }
}

@MainActor
protocol ReminderClient {
    func authorize() async throws -> Bool
    func replace(_ requests: [UNNotificationRequest]) async throws
    func cancel()
}

final class LocalReminderClient: ReminderClient {
    static let identifiers = ["expedition.return.1", "expedition.return.7"]
    let center = UNUserNotificationCenter.current()
    func authorize() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    func replace(_ requests: [UNNotificationRequest]) async throws {
        cancel()
        do { for request in requests { try await center.add(request) } }
        catch { cancel(); throw error }
    }
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
        center.removeDeliveredNotifications(withIdentifiers: Self.identifiers)
    }
}

struct ReminderPlan {
    static func requests(id: UUID, eventID: UUID, now: Date, calendar: Calendar) -> [UNNotificationRequest] {
        [1, 7].compactMap { days in
            guard let date = calendar.date(byAdding: .day, value: days, to: now) else { return nil }
            let content = UNMutableNotificationContent()
            content.title = "Экспедиция ждёт капитана"
            content.body = "Продолжите сохранённое погружение. Игра откроется на паузе."
            content.sound = .default
            content.userInfo = ["url": ReturnRoute(id: id).url.absoluteString, "eventID": eventID.uuidString]
            // Floating calendar components preserve local wall time after time-zone changes.
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return UNNotificationRequest(identifier: "expedition.return.\(days)", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        }
    }
}

/// Installed before SwiftUI creates its root. Pending routes survive cold-start ordering.
@MainActor
final class ReturnInbox: ObservableObject {
    static let shared = ReturnInbox()
    @Published var pending: URL?
    var opened: ((URL, UUID?) -> Void)?
    func receive(_ url: URL, eventID: UUID? = nil) {
        if let opened { opened(url, eventID) } else { pending = url; pendingEventID = eventID }
    }
    private var pendingEventID: UUID?
    func connect(_ handler: @escaping (URL, UUID?) -> Void) {
        opened = handler
        if let pending { handler(pending, pendingEventID); self.pending = nil; pendingEventID = nil }
    }
}

final class ReturnNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["url"] as? String, let url = URL(string: raw) {
            let eventID = (info["eventID"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in ReturnInbox.shared.receive(url, eventID: eventID) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class ExpeditionRecovery: ObservableObject {
    @Published private(set) var savedID: UUID?
    @Published private(set) var history: [ReturnEvent] = []
    @Published var message: String?
    @Published var replacement: ReturnRoute?
    private weak var engine: GameEngine?
    private let directory: URL
    private let client: any ReminderClient
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var generation = UUID()
    private var operations: Task<Void, Never>?
    private var resumedID: UUID?
    private var exited = false
    private var remindersPending = false
    private var saveURL: URL { directory.appendingPathComponent("expedition.json") }
    private var eventsURL: URL { directory.appendingPathComponent("events.json") }

    init(engine: GameEngine, directory: URL? = nil, client: any ReminderClient = LocalReminderClient(),
         now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) {
        self.engine = engine
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExpeditionReturn")
        self.client = client; self.now = now; self.calendar = calendar
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: eventsURL.path) {
                history = try JSONDecoder().decode([ReturnEvent].self, from: Data(contentsOf: eventsURL))
            }
        } catch { message = "Не удалось прочитать историю событий." }
        remindersPending = history.first { ["pushScheduled", "pushCancelled", "pushError"].contains($0.kind) }?.kind == "pushScheduled"
        if FileManager.default.fileExists(atPath: saveURL.path) {
            do { savedID = try load().id }
            catch { failure(); deleteSave() }
        } else { client.cancel() }
    }

    func load() throws -> ExpeditionSnapshot {
        let data = try Data(contentsOf: saveURL)
        guard data.count <= 5_000_000 else { throw RecoveryError.corrupt }
        // Bound all numeric payloads before any engine conversion to Int or geometry math.
        func validNumbers(_ value: Any) -> Bool {
            if let number = value as? NSNumber { return number.doubleValue.isFinite && abs(number.doubleValue) <= 1_000_000_000 }
            if let values = value as? [Any] { return values.allSatisfy(validNumbers) }
            if let values = value as? [String: Any] { return values.values.allSatisfy(validNumbers) }
            return true
        }
        guard validNumbers(try JSONSerialization.jsonObject(with: data)) else { throw RecoveryError.corrupt }
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else { throw RecoveryError.version }
        let save = try JSONDecoder().decode(ExpeditionSnapshot.self, from: data)
        guard !history.contains(where: { $0.expedition == save.id && ["completed", "gameOver", "saveDeleted"].contains($0.kind) }) else { throw RecoveryError.corrupt }
        guard save.hull > 0, save.hull <= 3, save.energy > 0, save.energy <= 100,
              save.level.size.width > 0, save.level.size.height > 0,
              save.samples >= 0, save.samples <= save.level.pickups.count, save.runElapsed >= 0,
              Set(save.pickups.map(\.id)).count == save.pickups.count,
              Set(save.mines.map(\.id)).count == save.mines.count else { throw RecoveryError.corrupt }
        return save
    }
    enum RecoveryError: Error { case version, corrupt }

    @discardableResult
    func save(exiting: Bool) -> Bool {
        guard let engine, engine.state == .playing || engine.state == .paused else { return true }
        if exiting && exited { return true }
        do {
            let snapshot = engine.snapshot()
            try JSONEncoder().encode(snapshot).write(to: saveURL, options: .atomic)
            savedID = snapshot.id
            record("save", title: "Экспедиция сохранена", text: "Положение, груз и состояние океана сохранены.")
            if exiting { exited = true; schedule(id: snapshot.id) }
            return true
        } catch { message = "Не удалось сохранить экспедицию. Повторите попытку."; return false }
    }

    func record(_ kind: String, title: String, text: String, id: UUID = UUID(), expedition: UUID? = nil, sourceEventID: UUID? = nil) {
        guard !history.contains(where: { $0.id == id }) else { return }
        let run = expedition ?? engine?.expeditionId.flatMap(UUID.init(uuidString:)) ?? savedID
        history.insert(ReturnEvent(id: id, expedition: run, date: now(), kind: kind, title: title, text: text, sourceEventID: sourceEventID), at: 0)
        engine?.captainLogger.record(kind, message: title, expedition: run ?? id, sobriety: .sober,
                                     details: ["domainEventID": id.uuidString])
        persistHistory()
    }
    private func persistHistory() {
        do { try JSONEncoder().encode(history).write(to: eventsURL, options: .atomic) }
        catch { message = "Не удалось сохранить историю событий." }
    }
    func markRead(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].read.toggle(); persistHistory()
    }
    enum Filter: String, CaseIterable { case all = "Все", unread = "Непрочитанные", notifications = "Уведомления" }
    func events(_ filter: Filter) -> [ReturnEvent] {
        history.filter { filter == .all || (filter == .unread ? !$0.read : $0.isNotification) }
    }
    func canOpen(_ event: ReturnEvent) -> Bool { event.expedition != nil && event.expedition == savedID }

    private func schedule(id: UUID) {
        generation = UUID()
        remindersPending = true
        let token = generation, date = now(), cal = calendar(), eventID = UUID()
        let prior = operations
        operations = Task { [weak self] in
            await prior?.value
            guard let self, self.generation == token else { return }
            do {
                self.client.cancel()
                guard try await self.client.authorize() else {
                    if self.generation == token { self.remindersPending = false }
                    return
                }
                guard self.generation == token else { return }
                try await self.client.replace(ReminderPlan.requests(id: id, eventID: eventID, now: date, calendar: cal))
                guard self.generation == token else { self.client.cancel(); return }
                self.record("pushScheduled", title: "Напоминания включены", text: "Завтра и через неделю в это же местное время.", id: eventID, expedition: id)
            } catch {
                guard self.generation == token else { return }
                self.remindersPending = false
                self.record("pushError", title: "Напоминания недоступны", text: "Сохранение можно открыть кнопкой «Продолжить».", expedition: id)
            }
        }
    }
    func cancelReminders() {
        generation = UUID(); client.cancel(); exited = false
        let prior = operations
        operations = Task { [client] in await prior?.value; client.cancel() }
        if remindersPending, let id = savedID {
            record("pushCancelled", title: "Напоминания отменены", text: "Оставшиеся напоминания этой экспедиции отменены.", expedition: id)
        }
        remindersPending = false
    }
    func settle() async { await operations?.value }
    func deleteSave() {
        cancelReminders()
        if let savedID { record("saveDeleted", title: "Сохранение удалено", text: "История экспедиции остаётся доступной.", expedition: savedID) }
        do {
            if FileManager.default.fileExists(atPath: saveURL.path) { try FileManager.default.removeItem(at: saveURL) }
            savedID = nil; resumedID = nil
        } catch { message = "Не удалось удалить сохранение." }
    }
    private func failure() {
        message = "Сохранение отсутствует, повреждено или несовместимо. Начните новую экспедицию на главном экране."
        record("restoreError", title: "Не удалось продолжить", text: message!)
    }
    func open(_ url: URL, pushEventID: UUID? = nil, confirmed: Bool = false) {
        guard let route = ReturnRoute(url: url), let engine else { failure(); return }
        if let pushEventID {
            if let index = history.firstIndex(where: { $0.id == pushEventID }) { history[index].read = true; persistHistory() }
            if !history.contains(where: { $0.kind == "pushOpened" && $0.sourceEventID == pushEventID }) {
                record("pushOpened", title: "Напоминание открыто", text: "Открываем сохранённую экспедицию.", expedition: route.id, sourceEventID: pushEventID)
            }
        }
        do {
            let snapshot = try load()
            guard snapshot.id == route.id else { failure(); return }
            let active = engine.state == .playing || engine.state == .paused
            if active && engine.expeditionId == route.id.uuidString {
                if resumedID != route.id { engine.pause(); cancelReminders(); resumedID = route.id }
                return
            }
            if active && !confirmed { replacement = route; return }
            engine.restore(snapshot); resumedID = route.id; exited = false
            cancelReminders()
            record("restore", title: "Экспедиция восстановлена", text: "Игра на паузе. Продолжите, когда будете готовы.")
        } catch {
            failure()
            if savedID == route.id { deleteSave() }
            if engine.state != .playing && engine.state != .paused { engine.returnToMenu() }
        }
    }
}

struct ReturnEventsView: View {
    @ObservedObject var recovery: ExpeditionRecovery
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ExpeditionRecovery.Filter = .all
    @AccessibilityFocusState private var titleFocused: Bool
    var body: some View {
        NavigationStack {
            List {
                Button("Готово") { dismiss() }.font(.body).frame(minHeight: 44).accessibilityIdentifier("closeEvents")
                Picker("Фильтр событий", selection: $filter) {
                    ForEach(ExpeditionRecovery.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("eventFilter").accessibilityFocused($titleFocused)
                if recovery.events(filter).isEmpty { Text("Нет событий").accessibilityIdentifier("emptyEvents") }
                ForEach(recovery.events(filter)) { event in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title).font(.headline)
                        Text(event.date, format: .dateTime.day().month().year().hour().minute())
                        Text(event.text)
                        Button(event.read ? "Прочитано · отметить непрочитанным" : "Не прочитано · отметить прочитанным") { recovery.markRead(event.id) }
                            .accessibilityHint("Меняет статус этого события")
                        if recovery.canOpen(event), let id = event.expedition {
                            Button("Открыть экспедицию") { dismiss(); open(ReturnRoute(id: id).url) }
                                .accessibilityHint("Открывает сохранение на паузе")
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("События")
            .onAppear { titleFocused = true }
        }
    }
}
