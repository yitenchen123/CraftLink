import SwiftUI

struct ContentView: View {
    @EnvironmentObject var terracottaManager: TerracottaManager
    var body: some View {
        LobbyView()
    }
}
