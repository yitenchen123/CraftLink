import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CreateRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var terracottaManager: TerracottaManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    /// 用户输入的 MC 端口。仅用于 RoomHistory 记录与 UI 提示；Terracotta 自己会从
    /// Minecraft 的「对局域网开放」多播里发现真实端口。
    @State private var port = "25565"
    @State private var isCopied = false
    @State private var isCreating = false
    @State private var showError = false

    /// 当前房间邀请码（从 `terracottaManager.currentInviteCode` 同步过来）。
    /// 在 Swift 侧不再自己生成邀请码，而是等 Terracotta Rust 侧生成（保证与
    /// HMCL/FCL/ZL2 的算法 100% 一致）。
    private var inviteCode: String? { terracottaManager.currentInviteCode }

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
                        Text("Minecraft 端口（仅用于记录，Terracotta 会自动发现）")
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

                    Text("请在 Minecraft 中点击「对局域网开放」\nCraftLink 会自动扫描并生成邀请码")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if isCreating && inviteCode == nil {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("正在扫描 Minecraft 局域网广播...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 20)
                    } else if let code = inviteCode, !code.isEmpty {
                        VStack(spacing: 16) {
                            Text("邀请码")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text(code)
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
                                Label("房主虚拟 IP: \(Constants.serverIP)", systemImage: "network")
                                Label("Scaffolding 端口: \(Constants.scaffoldingPort)", systemImage: "number")
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

                    // 房间状态卡片
                    if terracottaManager.status == .connecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(terracottaManager.stageDescription.isEmpty ? "正在启动虚拟网络..." : terracottaManager.stageDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    } else if terracottaManager.status == .connected {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("房间已就绪，其他玩家可通过邀请码加入")
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(10)
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

                    Button("关闭房间", role: .destructive) {
                        terracottaManager.stopVPN()
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
        .onChange(of: terracottaManager.currentInviteCode) { newCode in
            // Terracotta 生成邀请码后自动复制到剪贴板
            if let code = newCode, !code.isEmpty {
                UIPasteboard.general.string = code
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isCopied = false
                }
                // 写入历史记录
                let history = RoomHistory(
                    inviteCode: code,
                    role: .host,
                    port: port,
                    virtualIP: Constants.serverIP
                )
                historyStore.add(history)
            }
        }
        .onReceive(terracottaManager.$lastError) { error in
            if error != nil {
                showError = true
            }
        }
        .alert("启动失败", isPresented: $showError, actions: {
            Button("确定", role: .cancel) { }
        }, message: {
            Text(terracottaManager.lastError ?? "未知错误")
        })
    }

    private func startRoom() {
        isCreating = true
        // 不在 Swift 侧生成邀请码 — 让 Terracotta Rust 侧生成（保证与 HMCL/FCL/ZL2
        // 的 base-34 + mod-7 校验算法完全一致）。
        terracottaManager.createRoom(inviteCode: nil, port: port, playerName: nil) { error in
            isCreating = false
            if let error = error {
                print("Terracotta createRoom error: \(error.localizedDescription)")
            } else {
                // 真正的「创建成功」要等 currentInviteCode 出现，由 onChange 处理。
                // 这里只是 Rust 侧已开始 scanning。
                isCreating = true  // 保持 progress 显示，直到邀请码出现
            }
        }
        // 在邀请码出现前，如果状态变成 connected 或 error，应关闭 isCreating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if terracottaManager.status != .connecting {
                isCreating = false
            }
        }
    }

    private func copyCode() {
        guard let code = inviteCode else { return }
        UIPasteboard.general.string = code
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}
