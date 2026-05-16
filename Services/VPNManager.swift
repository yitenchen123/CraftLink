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
        }
    }
    
    func startWithInviteCode(_ inviteCode: String, completion: @escaping (Error?) -> Void) {
        guard InviteCodeService.isValid(inviteCode) else {
            completion(NSError(domain: "CraftLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效邀请码"]))
            return
        }
        currentInviteCode = inviteCode
        
        let sharedDefaults = UserDefaults(suiteName: "group.com.craftlink")
        sharedDefaults?.set(inviteCode, forKey: "currentInviteCode")
        sharedDefaults?.synchronize()
        
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = "com.craftlink.network-extension"
        config.serverAddress = "CraftLink VPN"
        config.providerConfiguration = ["inviteCode": inviteCode]
        
        vpnManager.loadFromPreferences { error in
            if let error = error { completion(error); return }
            self.vpnManager.protocolConfiguration = config
            self.vpnManager.localizedDescription = "CraftLink"
            self.vpnManager.isEnabled = true
            self.vpnManager.saveToPreferences { error in
                if let error = error { completion(error); return }
                do {
                    try (self.vpnManager.connection as! NETunnelProviderSession).startTunnel(options: nil)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }
    
    func stopVPN() {
        vpnManager.connection.stopVPNTunnel()
        currentInviteCode = nil
    }
}