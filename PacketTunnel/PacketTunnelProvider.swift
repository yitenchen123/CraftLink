import NetworkExtension
import OSLog

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.craftlink", category: "PacketTunnel")

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 原因 3 修复：日志写入 App Group 共享容器，而非 NE extension 的临时目录
        // extension 进程对共享容器确定有读写权限，避免 Rust 侧因路径权限返回 permission denied
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
            // 兜底：extension 容器的临时目录，确保 logPath 一定有值
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

        // 原因 1 修复：iOS 沙盒下 NEPacketTunnelProvider 绑定固定 UDP 端口
        // 在部分 iOS 版本会返回 EACCES / permission denied；
        // 且多个房主同网络会冲突。统一改为 listen_port=0 让系统随机分配，
        // 节点间通过公共发现服务器 + network_name 协调，无需固定端口。
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
            [tun]
            name = "utun"
            mtu = 1300
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

            // 原因 2 修复：socketFileDescriptor 是 NEPacketTunnelFlow 的私有属性，
            // KVC 在签名 IPA 上经常返回 nil 或抛异常。
            // 1) 用 try/catch 包裹 KVC，避免私有属性访问抛出 NSUndefinedKeyException 直接崩溃
            // 2) 失败时不再静默继续，必须回传错误，否则 EasyTier 内部拿不到 TUN fd
            //    会以 permission denied 形式冒出来
            var fd: Int32 = -1
            if let raw = try? self.packetFlow.value(forKey: "socketFileDescriptor") as? NSNumber {
                fd = raw.int32Value
            }

            if fd < 0 {
                os_log("Failed to obtain socketFileDescriptor from packetFlow (private KVC unavailable)",
                       log: self.log, type: .error)
                _ = rust_stop_network_instance()
                completionHandler(NSError(
                    domain: "CraftLink",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "TUN 文件描述符获取失败：iOS 沙盒拒绝访问 packetFlow 私有属性。请确认使用 TrollStore/越狱环境安装，或更新到支持 PacketFlow 公开 API 的版本。"]
                ))
                return
            }

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
