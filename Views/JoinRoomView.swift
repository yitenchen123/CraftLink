import SwiftUI

struct JoinRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
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
                        TextField("U/XXXX-XXXX-XXXX-XXXX", text: $inputCode)
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
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)

                            Text("在 Minecraft 中连接 \(Constants.serverIP):房主端口")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
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
        vpnManager.joinRoom(inviteCode: inputCode) { error in
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
