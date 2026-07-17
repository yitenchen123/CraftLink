import SwiftUI

struct LobbyView: View {
    @EnvironmentObject var terracottaManager: TerracottaManager
    @StateObject private var historyStore = RoomHistoryStore.shared

    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showSettings = false
    @State private var prefillCode: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()

                VStack(spacing: 30) {
                    VStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.system(size: 80))
                            .foregroundColor(Color(hex: "D34C3B"))

                        Text("CraftLink")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Minecraft 跨平台联机")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(terracottaManager.status.rawValue)
                            .font(.subheadline)
                        if let role = terracottaManager.currentRole {
                            Text("• \(role.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(20)

                    // 连接中显示 Terracotta 上报的具体阶段
                    if !terracottaManager.stageDescription.isEmpty {
                        Text(terracottaManager.stageDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    HStack(spacing: 20) {
                        Button(action: { showCreate = true }) {
                            VStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 32))
                                Text("创建房间")
                                    .font(.subheadline)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color(hex: "D34C3B"))
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        }

                        Button(action: { showJoin = true }) {
                            VStack(spacing: 8) {
                                Image(systemName: "arrowshape.bounce.right.fill")
                                    .font(.system(size: 32))
                                Text("加入房间")
                                    .font(.subheadline)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.gray.opacity(0.3))
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        }
                    }
                    // 房间运行中不允许再开新房间
                    .disabled(terracottaManager.status == .connecting || terracottaManager.status == .connected)

                    if let latest = historyStore.latest {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("最近房间")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }

                            Button(action: {
                                prefillCode = latest.inviteCode
                                showJoin = true
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: latest.role == .host ? "crown.fill" : "person.fill")
                                        .foregroundColor(Color(hex: "D34C3B"))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(latest.inviteCode)
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.medium)
                                        HStack(spacing: 8) {
                                            Text(latest.role.rawValue)
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(latest.role == .host ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                                .cornerRadius(4)
                                            Text(latest.formattedTime)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(12)
                            }
                            .foregroundColor(.primary)
                        }
                        .padding(.horizontal)
                    }

                    Spacer()

                    Text("兼容 HMCL / PCL-CE / FCL / ZL2 陶瓦联机协议")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 20)
                }
                .padding()
                .navigationTitle("陶瓦联机")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gear")
                                .font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showCreate) {
                    CreateRoomView()
                }
                .sheet(isPresented: $showJoin) {
                    if let code = prefillCode {
                        JoinRoomView(prefillCode: code)
                            .onDisappear { prefillCode = nil }
                    } else {
                        JoinRoomView()
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
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
