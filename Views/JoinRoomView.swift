import SwiftUI

struct JoinRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @State private var inputCode = ""
    @State private var isValid = false
    @State private var isConnecting = false
    @State private var showError = false
    
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
            
            VStack(spacing: 30) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 70))
                    .foregroundColor(Color(hex: "D34C3B"))
                
                Text("加入房间")
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
                            .font(.headline)
                        Text("房主虚拟 IP: 10.0.0.2")
                            .font(.system(.body, design: .monospaced))
                        Text("在 Minecraft 中连接 10.0.0.2:房主端口")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let error = vpnManager.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                    }
                    .padding()
                }
                
                Spacer()
            }
            .padding()
            .alert("连接失败", isPresented: $showError, actions: {
                Button("确定", role: .cancel) { }
            }, message: {
                Text(vpnManager.lastError ?? "未知错误")
            })
        }
        .onReceive(vpnManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
    }
    
    private func joinRoom() {
        isConnecting = true
        vpnManager.startWithInviteCode(inputCode) { error in
            isConnecting = false
            if let error = error {
                print("连接失败: \(error.localizedDescription)")
            } else {
                print("VPN connected")
            }
        }
    }
}