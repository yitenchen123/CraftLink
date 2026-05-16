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
    @Published var lastError: String?   // 新增：错误信息
    
    private let vpnManager = NEVPNManager.shared()
    
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
            case .disconnected: self.status = .disconnected
            case .connecting: self.status = .connecting
            case .connected: self.status = .connected
            case .disconnecting: self.status = .disconnecting
            @unknown default: self.status = .disconnected
            }
            if self.status == .connected {
                self.lastError = nil
            }
        }
    }
    
    func startWithInviteCode(_ inviteCode: String, port: String? = nil, completion: @escaping (Error?) -> Void) {
        guard InviteCodeService.isValid(inviteCode) else {
            let error = NSError(domain: "CraftLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "邀请码格式错误"])
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                completion(error)
            }
            return
        }
        
        currentInviteCode = inviteCode
        currentPort = port
        
        // 保存到共享 UserDefaults
        let sharedDefaults = UserDefaults(suiteName: "group.com.craftlink")
        sharedDefaults?.set(inviteCode, forKey: "currentInviteCode")
        sharedDefaults?.set(port, forKey: "currentPort")
        sharedDefaults?.synchronize()
        
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = "com.craftlink.packet-tunnel"
        config.serverAddress = "CraftLink VPN"
        config.providerConfiguration = [
            "inviteCode": inviteCode,
            "port": port ?? ""
        ]
        
        vpnManager.loadFromPreferences { error in
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
        lastError = nil
    }
}