import SwiftUI

@main
struct CraftLinkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vpnManager = VPNManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .preferredColorScheme(.dark)
        }
    }
}