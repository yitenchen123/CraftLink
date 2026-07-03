import NetworkExtension
import OSLog

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.craftlink", category: "PacketTunnel")

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 日志写入 App Group 共享容器，避免 Rust 侧因路径权限返回 permission denied
        let logPath: String
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupId) {
            let logDir = groupURL.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: logDir,
                withIntermediateDirectories: true
            )
            logPath = logDir.appendingPathComponent("easytier.log").path
        } else {
            logPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("easytier.log").path
        }

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
        let port = sharedDefaults?.string(forKey: "currentPort") ?? ""
        let networkName = InviteCodeService.networkName(from: inviteCode)

        os_log("Starting tunnel: isServer=%{public}d, network=%{public}@, port=%{public}@",
               log: log, type: .info, isServer, networkName, port)

        let localIP = isServer ? Constants.serverIP : Constants.clientIP
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Constants.serverIP)

        let ipv4 = NEIPv4Settings(addresses: [localIP], subnetMasks: [Constants.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1300

        let dns = NEDNSSettings(servers: ["223.5.5.5", "8.8.8.8"])
        settings.dnsSettings = dns

        // 关键修复：按 EasyTier 官方 iOS 示例的顺序执行
        // 1) 先 setTunnelNetworkSettings（系统创建 TUN）
        // 2) 从 packetFlow 获取 TUN fd
        // 3) 再 run_network_instance（此时不创建自己的 TUN）
        // 4) set_tun_fd 传入 fd
        // 原代码顺序反了：先 run_network_instance（含 [tun] 配置→EasyTier 自己
        // 尝试创建 TUN→iOS 沙盒拒绝→permission denied），这就是真因。
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }

            // 用 keyPath "socket.fileDescriptor" 获取 TUN fd（EasyTier 官方用法）
            // 原代码用 value(forKey: "socketFileDescriptor") 是错的 key 名
            var fd: Int32 = -1
            if let raw = try? self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber {
                fd = raw.int32Value
            }
            // 兼容旧版 iOS 的 fallback key
            if fd < 0, let raw = try? self.packetFlow.value(forKey: "socketFileDescriptor") as? NSNumber {
                fd = raw.int32Value
            }

            os_log("TUN fd obtained: %{public}d", log: self.log, type: .info, fd)

            if fd < 0 {
                os_log("Failed to obtain TUN fd from packetFlow", log: self.log, type: .error)
                completionHandler(NSError(
                    domain: "CraftLink",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "TUN 文件描述符获取失败：iOS 沙盒拒绝访问 packetFlow 私有属性。请确认使用 TrollStore/越狱环境安装。"]
                ))
                return
            }

            // 启动 EasyTier 网络实例
            // 注意：配置里不放 [tun]，避免 EasyTier 尝试自己创建 TUN 设备
            // TUN fd 由下面的 set_tun_fd 从系统 packetFlow 传入
            let tomlConfig = """
                instance_name = "craftlink"
                network_name = "\(networkName)"
                shared_key = "\(networkName)"
                listen_port = 0
                peers = [
                  "tcp://public.easytier.cn:11010",
                  "udp://public.easytier.cn:11010"
                ]
                enable_ipv6 = false
                """

            var cfgErrMsg: UnsafePointer<CChar>? = nil
            let runRet = rust_run_network_instance(tomlConfig, &cfgErrMsg)
            if runRet != 0, let msg = cfgErrMsg {
                let errorMsg = String(cString: msg)
                rust_free_string(msg)
                os_log("run_network_instance failed: %{public}@", log: self.log, type: .error, errorMsg)
                completionHandler(NSError(domain: "CraftLink", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "网络实例启动失败: \(errorMsg)"]))
                return
            }

            // 传入系统 TUN fd 给 EasyTier
            var fdErrMsg: UnsafePointer<CChar>? = nil
            let fdRet = rust_set_tun_fd(fd, &fdErrMsg)
            if fdRet != 0, let msg = fdErrMsg {
                let errorMsg = String(cString: msg)
                rust_free_string(msg)
                _ = rust_stop_network_instance()
                completionHandler(NSError(domain: "CraftLink", code: -4,
                                          userInfo: [NSLocalizedDescriptionKey: "TUN FD 设置失败: \(errorMsg)"]))
                return
            }
            os_log("TUN FD set successfully: %{public}d", log: self.log, type: .info, fd)
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
