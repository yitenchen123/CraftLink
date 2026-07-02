import NetworkExtension
import Combine

enum VPNStatus: String {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case disconnecting = "断开中"
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    @Published var status: VPNStatus = .disconnected
    @Published var currentInviteCode: String?
    @Published var currentPort: String?
    @Published var currentRole: RoomRole?
    @Published var lastError: String?

    private let vpnManager = NEVPNManager.shared()
    private let sharedDefaults = UserDefaults(suiteName: Constants.appGroupId)

    private init() {
        loadPreferences()
        observeStatus()
    }

    private func loadPreferences() {
        vpnManager.loadFromPreferences { _ in }
    }

    private func observeStatus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusChanged),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc private func vpnStatusChanged() {
        DispatchQueue.main.async {
            switch self.vpnManager.connection.status {
            case .disconnected:
                self.status = .disconnected
            case .connecting:
                self.status = .connecting
            case .connected:
                self.status = .connected
                self.lastError = nil
            case .disconnecting:
                self.status = .disconnecting
            case .invalid:
                self.status = .disconnected
            case .reasserting:
                self.status = .connecting
            @unknown default:
                self.status = .disconnected
            }
        }
    }

    func createRoom(inviteCode: String, port: String, completion: @escaping (Error?) -> Void) {
        configureAndStart(inviteCode: inviteCode, port: port, isServer: true, completion: completion)
    }

    func joinRoom(inviteCode: String, completion: @escaping (Error?) -> Void) {
        configureAndStart(inviteCode: inviteCode, port: nil, isServer: false, completion: completion)
    }

    private func configureAndStart(inviteCode: String, port: String?, isServer: Bool, completion: @escaping (Error?) -> Void) {
        guard InviteCodeService.isValid(inviteCode) else {
            let error = NSError(domain: "CraftLink", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "邀请码格式错误"])
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                completion(error)
            }
            return
        }

        currentInviteCode = inviteCode
        currentPort = port
        currentRole = isServer ? .host : .client

        sharedDefaults?.set(inviteCode, forKey: "currentInviteCode")
        sharedDefaults?.set(port ?? "", forKey: "currentPort")
        sharedDefaults?.set(isServer, forKey: "isServer")
        sharedDefaults?.synchronize()

        // 准备隧道配置
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = Constants.packetTunnelBundleId
        config.serverAddress = "CraftLink VPN"
        // 显式桥接为 NSObject 子类，避免 NETunnelProviderProtocol 序列化崩溃
        config.providerConfiguration = [
            "inviteCode": inviteCode as NSString,
            "port": (port ?? "") as NSString,
            "isServer": NSNumber(value: isServer)
        ]

        // 修复 permission denied：
        // 1) 先 loadFromPreferences 拉取已存在的 VPN 配置
        // 2) 写入新配置并 saveToPreferences
        // 3) saveToPreferences 成功后必须再 loadFromPreferences 一次，
        //    让系统真正落盘、授予权限并使 isEnabled 生效
        // 4) 确认 connection 是 NETunnelProviderSession 后再 startTunnel
        //    若用户从未授权 VPN，提示其到系统设置开启，避免直接 permission denied
        vpnManager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    completion(error)
                }
                return
            }

            self.vpnManager.protocolConfiguration = config
            self.vpnManager.localizedDescription = "CraftLink"
            self.vpnManager.isEnabled = true

            self.vpnManager.saveToPreferences { saveError in
                if let saveError = saveError {
                    DispatchQueue.main.async {
                        self.lastError = saveError.localizedDescription
                        completion(saveError)
                    }
                    return
                }

                // 关键：重新加载，让权限和配置真正生效后再启动
                self.vpnManager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        DispatchQueue.main.async {
                            self.lastError = loadError.localizedDescription
                            completion(loadError)
                        }
                        return
                    }

                    // 若 isEnabled 仍为 false，说明用户在系统设置里关闭了 VPN 权限
                    guard self.vpnManager.isEnabled else {
                        let err = NSError(
                            domain: "CraftLink",
                            code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "VPN 权限未开启，请前往 设置 > VPN 中允许 CraftLink"]
                        )
                        DispatchQueue.main.async {
                            self.lastError = err.localizedDescription
                            completion(err)
                        }
                        return
                    }

                    guard let session = self.vpnManager.connection as? NETunnelProviderSession else {
                        let err = NSError(
                            domain: "CraftLink",
                            code: -11,
                            userInfo: [NSLocalizedDescriptionKey: "VPN 会话不可用"]
                        )
                        DispatchQueue.main.async {
                            self.lastError = err.localizedDescription
                            completion(err)
                        }
                        return
                    }

                    do {
                        try session.startTunnel(options: nil)
                        DispatchQueue.main.async {
                            completion(nil)
                        }
                    } catch {
                        // 处理 NEVPNError.configurationReadWriteFailed / configurationStale 等
                        let message: String
                        if let neError = error as? NEVPNError {
                            switch neError.code {
                            case .configurationReadWriteFailed:
                                message = "VPN 配置读写失败，请检查 VPN 权限后重试"
                            case .configurationStale:
                                message = "VPN 配置已过期，正在重新加载..."
                                // 配置过期：重新 load 一次再尝试
                                self.vpnManager.loadFromPreferences { _ in
                                    do {
                                        try session.startTunnel(options: nil)
                                        DispatchQueue.main.async { completion(nil) }
                                    } catch {
                                        DispatchQueue.main.async {
                                            self.lastError = error.localizedDescription
                                            completion(error)
                                        }
                                    }
                                }
                                return
                            case .connectionFailed:
                                message = "VPN 连接失败：\(error.localizedDescription)"
                            default:
                                message = error.localizedDescription
                            }
                        } else {
                            message = error.localizedDescription
                        }
                        DispatchQueue.main.async {
                            self.lastError = message
                            completion(error)
                        }
                    }
                }
            }
        }
    }

    func stopVPN() {
        vpnManager.connection.stopVPNTunnel()

        currentInviteCode = nil
        currentPort = nil
        currentRole = nil
        lastError = nil

        sharedDefaults?.removeObject(forKey: "currentInviteCode")
        sharedDefaults?.removeObject(forKey: "currentPort")
        sharedDefaults?.removeObject(forKey: "isServer")
        sharedDefaults?.synchronize()
    }
}
