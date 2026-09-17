import Foundation
import UserNotifications

protocol DateProvider { func now() -> Date }
struct SystemDateProvider: DateProvider { func now() -> Date { Date() } }

struct ReminderPlanner {
    static let nearDeliveryDistance: CGFloat = 350
    static let lowEnergy: CGFloat = 25
    static let criticalHull = 1
    enum Tier: String { case hour, day, week }
    static func tier(for save: ExpeditionSnapshot) -> Tier {
        let returning = save.hasBlackBox || save.missionRun?.equipmentDelivered == true || save.missionRun?.droneRecovered == true
        let deliveringEquipment = save.missionRun?.mission == .currentStation && save.missionRun?.equipmentDelivered == false
        let destination = deliveringEquipment ? save.level.wreck : save.level.base
        let distance = hypot(save.position.x - destination.x, save.position.y - destination.y)
        if (returning || deliveringEquipment) && distance <= nearDeliveryDistance { return .hour }
        if returning || save.energy <= lowEnergy || save.hull <= criticalHull { return .day }
        return .week
    }
    static func requests(save: ExpeditionSnapshot, eventID: UUID, now: Date, calendar: Calendar, snoozed: Bool = false) -> [UNNotificationRequest] {
        let tier = snoozed ? Tier.day : tier(for: save)
        let delays: [(String, Calendar.Component, Int)] = tier == .hour
            ? [("hour", .hour, 1), ("7", .day, 7)]
            : tier == .day ? [("1", .day, 1), ("7", .day, 7)] : [("7", .day, 7)]
        return delays.compactMap { key, component, value in
            guard let date = calendar.date(byAdding: component, value: value, to: now) else { return nil }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "reminder.title")
            content.body = String(localized: "reminder.body")
            content.sound = .default
            content.categoryIdentifier = "EXPEDITION_RETURN"
            content.userInfo = ["url": ReturnRoute(id: save.id).url.absoluteString, "eventID": eventID.uuidString]
            return UNNotificationRequest(identifier: "expedition.return.\(key)", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false))
        }
    }
}
