import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    var body: some View {
        LobbyView()
    }
}
