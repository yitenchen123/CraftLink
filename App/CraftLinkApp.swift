import SwiftUI

@main
struct CraftLinkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var terracottaManager = TerracottaManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(terracottaManager)
                .preferredColorScheme(.dark)
        }
    }
}
