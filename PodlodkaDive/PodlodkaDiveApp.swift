import SwiftUI

@main
struct PodlodkaDiveApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
                .preferredColorScheme(.dark)
        }
    }
}
