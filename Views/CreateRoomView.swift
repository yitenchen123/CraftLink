import SwiftUI

struct CreateRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    @State private var inviteCode = ""
    @State private var port = "25565"
    @State private var isCopied = false
    @State private var isCreating = false
    @State private var showError = false
    @State private var showSuccess = false

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "house.circle.fill")
                        .font(.system(size: 70))
                        .foregroundColor(Color(hex: "D34C3B"))

                    Text("创建房间")
                        .font(.title2)
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minecraft 端口")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("25565", text: $port)
                                .keyboardType(.numberPad)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 120)
                            Spacer()
                        }
                    }
                    .padding(.horizontal)

                    Text("请在 Minecraft 中点击「对局域网开放」，输入相同的端口号")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if isCreating {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("正在启动 VPN...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 20)
                    } else if !inviteCode.isEmpty {
                        VStack(spacing: 16) {
                            Text("邀请码")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text(inviteCode)
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.bold)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(BlurView(style: .dark))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(hex: "D34C3B").opacity(0.3), lineWidth: 1)
                                )

                            Button(action: copyCode) {
                                HStack(spacing: 8) {
                                    Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                    Text(isCopied ? "已复制" : "复制邀请码")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(isCopied ? Color.green.opacity(0.8) : Color(hex: "D34C3B"))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .animation(.easeInOut(duration: 0.2), value: isCopied)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Label("虚拟 IP: \(Constants.serverIP)", systemImage: "network")
                                Label("端口: \(port)", systemImage: "number")
                                Label("角色: 房主", systemImage: "crown.fill")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(10)
                        }
                        .padding(.horizontal)
                    }

                    if vpnManager.status == .connected {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("VPN 已连接，其他玩家可通过邀请码加入")
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(10)

                        // 房间成员列表（由 ScaffoldingServer 维护）
                        if !vpnManager.players.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("房间成员（\(vpnManager.players.count)）")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                ForEach(vpnManager.players) { player in
                                    HStack(spacing: 10) {
                                        Image(systemName: player.kind == .host ? "crown.fill" : "person.fill")
                                            .foregroundColor(player.kind == .host ? .orange : .accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(player.name)
                                                .font(.subheadline)
                                            Text("\(player.vendor) · \(player.kind.rawValue)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                        }
                    } else if let error = vpnManager.lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                    }

                    Spacer(minLength: 40)

                    Button("关闭房间", role: .destructive) {
                        vpnManager.stopVPN()
                        dismiss()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .onAppear {
            startRoom()
        }
        .onReceive(vpnManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
        .alert("启动失败", isPresented: $showError, actions: {
            Button("确定", role: .cancel) { }
        }, message: {
            Text(vpnManager.lastError ?? "未知错误")
        })
        .alert("创建成功", isPresented: $showSuccess, actions: {
            Button("确定", role: .cancel) { }
        }, message: {
            Text("房间已创建，邀请码已复制到剪贴板。")
        })
    }

    private func startRoom() {
        isCreating = true
        inviteCode = InviteCodeService.generate()

        UIPasteboard.general.string = inviteCode
        isCopied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }

        vpnManager.createRoom(inviteCode: inviteCode, port: port) { error in
            isCreating = false
            if error == nil {
                showSuccess = true
                let history = RoomHistory(
                    inviteCode: inviteCode,
                    role: .host,
                    port: port,
                    virtualIP: Constants.serverIP
                )
                historyStore.add(history)
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
