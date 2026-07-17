import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var terracottaManager: TerracottaManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    @State private var showClearConfirm = false
    @State private var showJoinSheet = false
    @State private var selectedCode: String?

    var body: some View {
        NavigationView {
            List {
                Section("联机状态") {
                    HStack {
                        Text("状态")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(terracottaManager.status.rawValue)
                                .foregroundColor(statusColor)
                        }
                    }

                    if let code = terracottaManager.currentInviteCode {
                        HStack {
                            Text("当前房间")
                            Spacer()
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    if let role = terracottaManager.currentRole {
                        HStack {
                            Text("角色")
                            Spacer()
                            Text(role.rawValue)
                                .foregroundColor(role == .host ? .orange : .blue)
                        }
                    }

                    if let port = terracottaManager.currentPort, !port.isEmpty {
                        HStack {
                            Text("MC 端口")
                            Spacer()
                            Text(port)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let url = terracottaManager.directConnectURL {
                        HStack {
                            Text("MC 直连地址")
                            Spacer()
                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    if !terracottaManager.stageDescription.isEmpty {
                        HStack {
                            Text("阶段")
                            Spacer()
                            Text(terracottaManager.stageDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if terracottaManager.status == .connected || terracottaManager.status == .connecting {
                        Button("断开连接", role: .destructive) {
                            terracottaManager.stopVPN()
                        }
                    }
                }

                Section {
                    if historyStore.histories.isEmpty {
                        Text("暂无历史记录")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(historyStore.histories) { history in
                            HistoryRow(history: history)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedCode = history.inviteCode
                                    showJoinSheet = true
                                }
                        }
                        .onDelete(perform: historyStore.remove)

                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空所有记录", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("历史房间")
                } footer: {
                    Text("点击房间可一键重连，左滑可删除单条记录")
                        .font(.caption)
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }

                    if let metadata = TerracottaBridge.metadata() {
                        HStack {
                            Text("Terracotta")
                            Spacer()
                            Text("v\(metadata.version)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("EasyTier")
                            Spacer()
                            Text(metadata.easytierVersion)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/yitenchen123/CraftLink")!) {
                        HStack {
                            Text("GitHub 仓库")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/burningtnt/Terracotta")!) {
                        HStack {
                            Text("Powered by Terracotta")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/EasyTier/EasyTier")!) {
                        HStack {
                            Text("EasyTier 网络")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("确认清空", isPresented: $showClearConfirm, actions: {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    historyStore.removeAll()
                }
            }, message: {
                Text("确定要清空所有历史房间记录吗？此操作不可撤销。")
            })
            .sheet(isPresented: $showJoinSheet) {
                if let code = selectedCode {
                    JoinRoomView(prefillCode: code)
                }
            }
        }
    }

    private var statusColor: Color {
        switch terracottaManager.status {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }
}

struct HistoryRow: View {
    let history: RoomHistory

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(roleColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: history.role == .host ? "crown.fill" : "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(roleColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(history.inviteCode)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(history.role.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(roleColor.opacity(0.15))
                        .foregroundColor(roleColor)
                        .cornerRadius(4)

                    if let port = history.port, !port.isEmpty {
                        Text("端口 \(port)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text(history.formattedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var roleColor: Color {
        history.role == .host ? .orange : .blue
    }
}
