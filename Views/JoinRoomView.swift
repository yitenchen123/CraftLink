import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct JoinRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var terracottaManager: TerracottaManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    @State private var inputCode = ""
    @State private var isValid = false
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
                                // 用 Terracotta Rust 侧的校验函数（与 HMCL/FCL/ZL2 一致）
                                isValid = TerracottaBridge.verifyRoomCode(newValue)
                            }
                    }
                    .padding(.horizontal)

                    if !inputCode.isEmpty && !isValid {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                            Text("邀请码格式不正确（应为 U/NNNN-NNNN-SSSS-SSSS）")
                                .font(.caption)
                        }
                        .padding(.horizontal)
                    }

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

                    // 状态卡片
                    if terracottaManager.status == .connecting {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(terracottaManager.stageDescription.isEmpty ? "正在连接房主..." : terracottaManager.stageDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal)
                    } else if terracottaManager.status == .connected {
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
                                if let url = terracottaManager.directConnectURL {
                                    Label("MC 直连地址: \(url)", systemImage: "link")
                                        .foregroundColor(.green)
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)

                            if let url = terracottaManager.directConnectURL {
                                Text("在 Minecraft 多人游戏 → 直接连接 中输入：\(url)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("已连接，等待 port_forward 就绪...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal)
                    } else if terracottaManager.status == .error {
                        if let error = terracottaManager.lastError {
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
                    }

                    // 房间成员列表（由 Terracotta Rust 侧通过 Scaffolding 协议同步）
                    if !terracottaManager.players.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("房间成员（\(terracottaManager.players.count)）")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            ForEach(terracottaManager.players) { player in
                                HStack(spacing: 10) {
                                    Image(systemName: player.kind == "HOST" ? "crown.fill" : "person.fill")
                                        .foregroundColor(player.kind == "HOST" ? .orange : .accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(player.name)
                                            .font(.subheadline)
                                        Text("\(player.vendor) · \(player.kind)")
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
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 40)

                    if terracottaManager.status == .connected || terracottaManager.status == .connecting {
                        Button("断开连接", role: .destructive) {
                            terracottaManager.stopVPN()
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
                isValid = TerracottaBridge.verifyRoomCode(code)
            }
        }
        .onReceive(terracottaManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
        .alert("连接失败", isPresented: $showError, actions: {
            Button("确定", role: .cancel) { }
        }, message: {
            Text(terracottaManager.lastError ?? "未知错误")
        })
    }

    private func joinRoom() {
        isConnecting = true
        terracottaManager.joinRoom(inviteCode: inputCode, playerName: nil) { error in
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
