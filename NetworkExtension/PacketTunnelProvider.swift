import NetworkExtension
import OSLog

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.craftlink", category: "PacketTunnel")
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 初始化日志
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("easytier.log").path
        var errMsg: UnsafePointer<CChar>? = nil
        let ret = rust_init_logger(logPath, "info", "CraftLink", &errMsg)
        if ret != 0, let msg = errMsg {
            let errorMsg = String(cString: msg)
            rust_free_string(msg)
            completionHandler(NSError(domain: "CraftLink", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
            return
        }
        
        // 2. 读取邀请码
        let sharedDefaults = UserDefaults(suiteName: "group.com.craftlink")
        let inviteCode = sharedDefaults?.string(forKey: "currentInviteCode") ?? ""
        let isServer = inviteCode.hasPrefix("U/")
        let networkName = InviteCodeService.networkName(from: inviteCode)
        
        // 3. 生成 TOML 配置
        let tomlConfig = """
            instance_name = "craftlink"
            network_name = "\(networkName)"
            shared_key = "\(networkName)"
            listen_port = \(isServer ? 11010 : 0)
            peers = []
            enable_ipv6 = false
            [tun]
            name = "utun"
            """
        
        var cfgErrMsg: UnsafePointer<CChar>? = nil
        let runRet = rust_run_network_instance(tomlConfig, &cfgErrMsg)
        if runRet != 0, let msg = cfgErrMsg {
            let errorMsg = String(cString: msg)
            rust_free_string(msg)
            completionHandler(NSError(domain: "CraftLink", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
            return
        }
        
        // 4. 配置虚拟网卡
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1300
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            // 5. 获取 TUN fd 并传递给 Rust
            // 使用 packetFlow 获取 socketFileDescriptor（标准做法）
            if let fd = self.packetFlow.value(forKey: "socketFileDescriptor") as? Int32 {
                var fdErrMsg: UnsafePointer<CChar>? = nil
                let fdRet = rust_set_tun_fd(fd, &fdErrMsg)
                if fdRet != 0, let msg = fdErrMsg {
                    let errorMsg = String(cString: msg)
                    rust_free_string(msg)
                    completionHandler(NSError(domain: "CraftLink", code: -3, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
                    return
                }
            } else {
                os_log("Failed to obtain socketFileDescriptor from packetFlow", log: self.log, type: .error)
                // 不强制失败，因为某些情况下可能不需要
            }
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let result = rust_stop_network_instance()
        os_log("Rust network instance stopped with result: %d", log: log, type: .info, result)
        completionHandler()
    }
}