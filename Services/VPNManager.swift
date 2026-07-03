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

    // 关键修复：用 NETunnelProviderManager 代替 NEVPNManager
    // NEVPNManager 用于系统 VPN（IKEv2/IPSec），管理自定义 PacketTunnelProvider
    // 必须用 NETunnelProviderManager，否则 startTunnel 会被系统拒绝
    private var tunnelManager: NETunnelProviderManager?
    private let sharedDefaults = UserDefaults(suiteName: Constants.appGroupId)

    private init() {
        loadPreferences()
        observeStatus()
    }

    private func loadPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            // 找到已有的 CraftLink 配置，或准备创建新的
            self?.tunnelManager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Constants.packetTunnelBundleId
            }) ?? NETunnelProviderManager()
            self?.updateStatus()
        }
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
            self.updateStatus()
        }
    }

    private func updateStatus() {
        guard let connection = tunnelManager?.connection else {
            status = .disconnected
            return
        }
        switch connection.status {
        case .disconnected:
            status = .disconnected
            // 读取 PacketTunnel 写回的具体错误信息
            if let tunnelErr = sharedDefaults?.string(forKey: "tunnelError") {
                DispatchQueue.main.async {
                    self.lastError = tunnelErr
                }
            }
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
            lastError = nil
        case .disconnecting:
            status = .disconnecting
        case .invalid:
            status = .disconnected
        case .reasserting:
            status = .connecting
        @unknown default:
            status = .disconnected
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
        config.providerConfiguration = [
            "inviteCode": inviteCode as NSString,
            "port": (port ?? "") as NSString,
            "isServer": NSNumber(value: isServer)
        ]

        // 获取或创建 tunnelManager，然后配置并启动
        let manager = tunnelManager ?? NETunnelProviderManager()
        tunnelManager = manager

        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    completion(error)
                }
                return
            }

            manager.protocolConfiguration = config
            manager.localizedDescription = "CraftLink"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    DispatchQueue.main.async {
                        self.lastError = saveError.localizedDescription
                        completion(saveError)
                    }
                    return
                }

                // 重新加载，让权限和配置真正生效后再启动
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        DispatchQueue.main.async {
                            self.lastError = loadError.localizedDescription
                            completion(loadError)
                        }
                        return
                    }

                    guard manager.isEnabled else {
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

                    guard let session = manager.connection as? NETunnelProviderSession else {
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
                        // startTunnel 立即抛异常 = extension 无法加载（签名/权限问题）
                        // 延迟读取 tunnelError（PacketTunnel 可能已写入更具体的错误）
                        let nsError = error as NSError
                        let detail = "[错误码 \(nsError.domain):\(nsError.code)] \(error.localizedDescription)"
                        DispatchQueue.main.async {
                            self.lastError = detail
                            completion(error)
                        }
                        // 延迟再读一次 tunnelError，PacketTunnel 可能在 completionHandler 里写了
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if let tunnelErr = self.sharedDefaults?.string(forKey: "tunnelError"),
                               !tunnelErr.isEmpty {
                                self.lastError = tunnelErr
                            }
                        }
                    }
                }
            }
        }
    }

    func stopVPN() {
        tunnelManager?.connection.stopVPNTunnel()

        currentInviteCode = nil
        currentPort = nil
        currentRole = nil
        lastError = nil

        sharedDefaults?.removeObject(forKey: "currentInviteCode")
        sharedDefaults?.removeObject(forKey: "currentPort")
        sharedDefaults?.removeObject(forKey: "isServer")
        sharedDefaults?.removeObject(forKey: "tunnelError")
        sharedDefaults?.synchronize()
    }
}
