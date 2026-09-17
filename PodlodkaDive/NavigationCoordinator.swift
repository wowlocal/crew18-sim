import Foundation
import Observation
import AppIntents
import UserNotifications

/// All external and in-app destinations share this serializable contract.
enum AppRoute: Codable, Equatable {
    case expedition(UUID), campaign(CampaignMission), journal(UUID?), blackBox(UUID), events, briefing(UUID)
    case continueExpedition, postpone(UUID)
}

struct DeepLinkParser {
    static func parse(_ url: URL) -> AppRoute? {
        guard url.scheme?.lowercased() == "podlodkadive", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.isEmpty {
            switch url.host {
            case "events": return .events
            case "journal": return .journal(nil)
            case "continue": return .continueExpedition
            default: return nil
            }
        }
        guard parts.count == 1 else { return nil }
        if url.host == "campaign", let mission = CampaignMission(rawValue: parts[0]) { return .campaign(mission) }
        guard let id = UUID(uuidString: parts[0]) else { return nil }
        switch url.host {
        case "expedition": return .expedition(id)
        case "briefing": return .briefing(id)
        case "journal": return .journal(id)
        case "blackbox": return .blackBox(id)
        default: return nil
        }
    }
}

@MainActor @Observable
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()
    private(set) var pending: AppRoute?
    private var pendingEvent: UUID?
    private var handler: ((AppRoute, UUID?) -> Void)?
    private var last: AppRoute?
    private var lastDate = Date.distantPast
    private let now: () -> Date
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    func receive(_ route: AppRoute, eventID: UUID? = nil) {
        let date = now()
        guard route != last || date.timeIntervalSince(lastDate) >= 1 else { return }
        last = route; lastDate = date
        if let handler { handler(route, eventID) }
        else { pending = route; pendingEvent = eventID }
    }
    func connect(_ handler: @escaping (AppRoute, UUID?) -> Void) {
        self.handler = handler
        if let pending {
            let event = pendingEvent
            self.pending = nil; pendingEvent = nil
            handler(pending, event)
        }
    }
}

struct ContinueExpeditionIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.continue"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        NavigationCoordinator.shared.receive(.continueExpedition)
        return .result()
    }
}
struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.journal"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        NavigationCoordinator.shared.receive(.journal(nil))
        return .result()
    }
}
struct CaptainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueExpeditionIntent(), phrases: ["Continue expedition in \(.applicationName)", "Продолжи экспедицию в \(.applicationName)"], shortTitle: "shortcut.continue", systemImageName: "play.fill")
        AppShortcut(intent: OpenJournalIntent(), phrases: ["Open journal in \(.applicationName)", "Открой журнал в \(.applicationName)"], shortTitle: "shortcut.journal", systemImageName: "book")
    }
}


struct NotificationRoute {
    static func resolve(url: URL, action: String) -> AppRoute? {
        guard let route = DeepLinkParser.parse(url) else { return nil }
        switch action {
        case "LATER":
            guard case .expedition(let id) = route else { return nil }
            return .postpone(id)
        case "CONTINUE", UNNotificationDefaultActionIdentifier: return route
        default: return nil
        }
    }
}
