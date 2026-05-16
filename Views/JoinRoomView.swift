import SwiftUI

struct JoinRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @State private var inputCode = ""
    @State private var isValid = false
    @State private var isConnecting = false
    
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
            
            VStack(spacing: 30) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 70))
                    .foregroundColor(Color(hex: "D34C3B"))
                
                Text("输入邀请码")
                    .font(.title2)
                
                TextField("U/XXXX-XXXX-XXXX-XXXX", text: $inputCode)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .padding()
                    .background(BlurView(style: .dark))
                    .cornerRadius(12)
                    .onChange(of: inputCode) { newValue in
                        isValid = InviteCodeService.isValid(newValue)
                    }
                
                if !inputCode.isEmpty && !isValid {
                    Text("邀请码格式不正确")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Button(action: joinRoom) {
                    HStack {
                        if isConnecting {
                            ProgressView()
                        } else {
                            Image(systemName: "network")
                            Text("连接房间")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValid ? Color(hex: "D34C3B") : Color.gray)
                    .cornerRadius(12)
                }
                .disabled(!isValid || isConnecting)
                
                if vpnManager.status == .connected {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.largeTitle)
                        Text("已加入房间")
                        Text("现在打开 Minecraft，点击多人游戏 -> 局域网世界")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
    
    private func joinRoom() {
        isConnecting = true
        vpnManager.startWithInviteCode(inputCode) { error in
            isConnecting = false
            if error == nil {
                // 保存历史记录 (简单实现，可扩展)
            }
        }
    }
}