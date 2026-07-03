import SwiftUI

struct JoinRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    @State private var inputCode = ""
    @State private var isValid = false
    @State private var hostPortText = ""
    @State private var isConnecting = false
    @State private var showError = false
    @State private var prefillCode: String?

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 70))
                        .foregroundColor(Color(hex: "D34C3B"))

                    Text("加入房间")
                        .font(.title2)
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("邀请码")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("U/NNNN-NNNN-SSSS-SSSS", text: $inputCode)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.allCharacters)
                            .disableAutocorrection(true)
                            .padding()
                            .background(BlurView(style: .dark))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isValid ? Color.green.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .onChange(of: inputCode) { newValue in
                                isValid = InviteCodeService.isValid(newValue)
                            }
                    }
                    .padding(.horizontal)

                    if !inputCode.isEmpty && !isValid {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                            Text("邀请码格式不正确")
                                .font(.caption)
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("房主 MC 端口（可选，用于显示房间成员）")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("如 25565", text: $hostPortText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.horizontal)

                    Button(action: joinRoom) {
                        HStack(spacing: 8) {
                            if isConnecting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                                Text("连接房间")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isValid && !isConnecting ? Color(hex: "D34C3B") : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.2), value: isValid)
                    }
                    .disabled(!isValid || isConnecting)
                    .padding(.horizontal)

                    if vpnManager.status == .connected {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 50))

                            Text("已加入房间")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 10) {
                                Label("房主虚拟 IP: \(Constants.serverIP)", systemImage: "network")
                                Label("你的虚拟 IP: \(Constants.clientIP)", systemImage: "person.fill")
                                Label("角色: 加入者", systemImage: "person.2.fill")
                                if let mcPort = vpnManager.discoveredMCPort {
                                    Label("房主 MC 端口: \(mcPort)", systemImage: "number")
                                        .foregroundColor(.green)
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)

                            if let mcPort = vpnManager.discoveredMCPort {
                                Text("在 Minecraft 多人游戏 → 直接连接 中输入：\(Constants.serverIP):\(mcPort)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("已连接 VPN。如未填端口，请在 Minecraft 中尝试 \(Constants.serverIP):房主端口")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }

                            // 房间成员列表（由 ScaffoldingClient 同步）
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
                        }
                        .padding(.horizontal)
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
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 40)

                    if vpnManager.status == .connected {
                        Button("断开连接", role: .destructive) {
                            vpnManager.stopVPN()
                            dismiss()
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .onAppear {
            if let code = prefillCode {
                inputCode = code
                isValid = InviteCodeService.isValid(code)
            }
        }
        .onReceive(vpnManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
        .alert("连接失败", isPresented: $showError, actions: {
            Button("确定", role: .cancel) { }
        }, message: {
            Text(vpnManager.lastError ?? "未知错误")
        })
    }

    private func joinRoom() {
        isConnecting = true
        // 解析房主端口（可选）。提供时启动 ScaffoldingClient 以同步房间成员与 MC 端口。
        let hostPort: UInt16? = {
            let trimmed = hostPortText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let p = UInt16(trimmed), p > 0 else { return nil }
            return p
        }()
        vpnManager.joinRoom(inviteCode: inputCode, hostPort: hostPort) { error in
            isConnecting = false
            if let error = error {
                print("连接失败: \(error.localizedDescription)")
            } else {
                let history = RoomHistory(
                    inviteCode: inputCode,
                    role: .client,
                    virtualIP: Constants.clientIP
                )
                historyStore.add(history)
            }
        }
    }
}

extension JoinRoomView {
    init(prefillCode: String? = nil) {
        _prefillCode = State(initialValue: prefillCode)
    }
}
