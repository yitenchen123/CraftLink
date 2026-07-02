import NetworkExtension
import OSLog

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.craftlink", category: "PacketTunnel")

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("easytier.log").path
        var errMsg: UnsafePointer<CChar>? = nil
        let ret = rust_init_logger(logPath, "info", "CraftLink", &errMsg)
        if ret != 0, let msg = errMsg {
            let errorMsg = String(cString: msg)
            rust_free_string(msg)
            completionHandler(NSError(domain: "CraftLink", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "日志初始化失败: \(errorMsg)"]))
            return
        }

        let sharedDefaults = UserDefaults(suiteName: Constants.appGroupId)
        let inviteCode = sharedDefaults?.string(forKey: "currentInviteCode") ?? ""
        let isServer = sharedDefaults?.bool(forKey: "isServer") ?? false
        let networkName = InviteCodeService.networkName(from: inviteCode)

        os_log("Starting tunnel: isServer=%{public}d, network=%{public}@",
               log: log, type: .info, isServer, networkName)

        let tomlConfig = """
            instance_name = "craftlink"
            network_name = "\(networkName)"
            shared_key = "\(networkName)"
            listen_port = \(isServer ? Constants.serverPort : 0)
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
            completionHandler(NSError(domain: "CraftLink", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "网络实例启动失败: \(errorMsg)"]))
            return
        }

        let localIP = isServer ? Constants.serverIP : Constants.clientIP
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Constants.serverIP)

        let ipv4 = NEIPv4Settings(addresses: [localIP], subnetMasks: [Constants.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1300

        let dns = NEDNSSettings(servers: ["223.5.5.5", "8.8.8.8"])
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }

            if let fd = self.packetFlow.value(forKey: "socketFileDescriptor") as? Int32 {
                var fdErrMsg: UnsafePointer<CChar>? = nil
                let fdRet = rust_set_tun_fd(fd, &fdErrMsg)
                if fdRet != 0, let msg = fdErrMsg {
                    let errorMsg = String(cString: msg)
                    rust_free_string(msg)
                    completionHandler(NSError(domain: "CraftLink", code: -3,
                                              userInfo: [NSLocalizedDescriptionKey: "TUN FD 设置失败: \(errorMsg)"]))
                    return
                }
                os_log("TUN FD set successfully: %{public}d", log: self.log, type: .info, fd)
            } else {
                os_log("Warning: Failed to obtain socketFileDescriptor from packetFlow", log: self.log, type: .error)
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let result = rust_stop_network_instance()
        os_log("Rust network instance stopped with result: %{public}d", log: log, type: .info, result)
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            os_log("Received app message: %{public}@", log: log, type: .info, message)
        }
        completionHandler?(nil)
    }
}
