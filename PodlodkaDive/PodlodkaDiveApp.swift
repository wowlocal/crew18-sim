import SwiftUI

@main
struct PodlodkaDiveApp: App {
    @UIApplicationDelegateAdaptor(ReturnNotificationDelegate.self) private var notificationDelegate
    var body: some Scene {
        WindowGroup {
            GameView()
                .preferredColorScheme(.dark)
        }
    }
}
