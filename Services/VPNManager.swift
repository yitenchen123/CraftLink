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

        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = Constants.packetTunnelBundleId
        config.serverAddress = "CraftLink VPN"
        config.providerConfiguration = [
            "inviteCode": inviteCode,
            "port": port ?? "",
            "isServer": isServer
        ] as [String: NSObject]

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
            self.vpnManager.saveToPreferences { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.lastError = error.localizedDescription
                        completion(error)
                    }
                    return
                }
                do {
                    try (self.vpnManager.connection as! NETunnelProviderSession).startTunnel(options: nil)
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.lastError = error.localizedDescription
                        completion(error)
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
