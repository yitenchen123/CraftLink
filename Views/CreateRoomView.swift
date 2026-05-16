import SwiftUI

struct CreateRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @State private var inviteCode = ""
    @State private var port = "25565"
    @State private var isCopied = false
    @State private var isCreating = false
    @State private var showError = false
    
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
            
            VStack(spacing: 20) {
                Image(systemName: "house.circle.fill")
                    .font(.system(size: 70))
                    .foregroundColor(Color(hex: "D34C3B"))
                
                Text("创建房间")
                    .font(.title2)
                
                HStack {
                    Text("Minecraft 端口:")
                    TextField("25565", text: $port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                }
                .padding(.horizontal)
                
                Text("请在 Minecraft 中点击「对局域网开放」，输入相同的端口号")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                if isCreating {
                    ProgressView("正在启动 VPN...")
                        .padding()
                } else if !inviteCode.isEmpty {
                    VStack(spacing: 16) {
                        Text("邀请码")
                            .font(.headline)
                        Text(inviteCode)
                            .font(.system(.title, design: .monospaced))
                            .padding()
                            .background(BlurView(style: .dark))
                            .cornerRadius(12)
                        
                        Button(action: copyCode) {
                            HStack {
                                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                Text(isCopied ? "已复制" : "复制邀请码")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(hex: "D34C3B"))
                            .cornerRadius(12)
                        }
                        .disabled(isCopied)
                    }
                    .padding(.horizontal)
                }
                
                if vpnManager.status == .connected {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("VPN 已连接，其他玩家可通过邀请码加入")
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
                
                Button("关闭房间", role: .destructive) {
                    vpnManager.stopVPN()
                    dismiss()
                }
                .padding()
            }
            .padding()
            .alert("启动失败", isPresented: $showError, actions: {
                Button("确定", role: .cancel) { }
            }, message: {
                Text(vpnManager.lastError ?? "未知错误")
            })
        }
        .onAppear {
            startRoom()
        }
        .onReceive(vpnManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
    }
    
    private func startRoom() {
        isCreating = true
        inviteCode = InviteCodeService.generate()
        UIPasteboard.general.string = inviteCode
        isCopied = true
        vpnManager.startWithInviteCode(inviteCode, port: port) { error in
            isCreating = false
            if error == nil {
                print("VPN started successfully")
            } else {
                print("VPN start error: \(error?.localizedDescription ?? "")")
            }
        }
    }
    
    private func copyCode() {
        UIPasteboard.general.string = inviteCode
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}