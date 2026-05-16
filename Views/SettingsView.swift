import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    
    var body: some View {
        List {
            Section("VPN 状态") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(vpnManager.status.rawValue)
                        .foregroundColor(vpnManager.status == .connected ? .green : .secondary)
                }
                if vpnManager.status == .connected, let code = vpnManager.currentInviteCode {
                    HStack {
                        Text("当前房间")
                        Spacer()
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Button("断开连接") {
                    vpnManager.stopVPN()
                }
                .disabled(vpnManager.status != .connected)
            }
            
            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
                Link("GitHub 仓库", destination: URL(string: "https://github.com/yitenchen123/CraftLink")!)
            }
        }
        .navigationTitle("设置")
    }
}