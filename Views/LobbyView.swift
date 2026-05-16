import SwiftUI

struct LobbyView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var showCreate = false
    @State private var showJoin = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
                
                VStack(spacing: 30) {
                    Image(systemName: "network")
                        .font(.system(size: 80))
                        .foregroundColor(Color(hex: "D34C3B"))
                    
                    Text("CraftLink")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    HStack(spacing: 40) {
                        Button(action: { showCreate = true }) {
                            Label("创建房间", systemImage: "plus.circle.fill")
                                .frame(width: 140, height: 50)
                                .background(Color(hex: "D34C3B"))
                                .cornerRadius(12)
                        }
                        
                        Button(action: { showJoin = true }) {
                            Label("加入房间", systemImage: "arrowshape.bounce.right.fill")
                                .frame(width: 140, height: 50)
                                .background(Color.gray.opacity(0.3))
                                .cornerRadius(12)
                        }
                    }
                    
                    Text("VPN状态: \(vpnManager.status.rawValue)")
                        .padding()
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("陶瓦联机")
                .sheet(isPresented: $showCreate) {
                    CreateRoomView()
                }
                .sheet(isPresented: $showJoin) {
                    JoinRoomView()
                }
            }
        }
    }
}

// 颜色扩展
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}