import NetworkExtension
import OSLog

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.craftlink", category: "PacketTunnel")
    private let sharedDefaults = UserDefaults(suiteName: Constants.appGroupId)
    /// EasyTier 启动用的串行队列（避免阻塞 startTunnel completionHandler）。
    private let easytierQueue = DispatchQueue(label: "com.craftlink.easytier")
    /// 标记是否已调用 startTunnel completionHandler（防止重复调用）。
    private var startCompletionCalled = false
    /// 标记 EasyTier 是否已就绪（防止 ready 阶段被重复上报）。
    private var easytierReady = false

    /// 把错误信息写回 App Group，让主 App 能读到具体失败原因。
    /// - Returns: 同样的 NSError，方便 `cancelTunnelWithError` 使用。
    private func reportError(_ message: String, code: Int) -> Error {
        let error = NSError(domain: "CraftLink", code: code,
                            userInfo: [NSLocalizedDescriptionKey: message])
        sharedDefaults?.set(message, forKey: Constants.AppGroupKey.tunnelError)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: Constants.AppGroupKey.tunnelErrorTime)
        sharedDefaults?.synchronize()
        os_log("TUNNEL ERROR: %{public}@", log: log, type: .error, message)
        return error
    }

    /// 上报启动阶段到 App Group，主 App 据此显示「正在初始化 / 正在启动 EasyTier / 就绪」。
    private func reportStage(_ stage: String) {
        sharedDefaults?.set(stage, forKey: Constants.AppGroupKey.tunnelStage)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: Constants.AppGroupKey.tunnelStageTime)
        sharedDefaults?.synchronize()
        os_log("TUNNEL STAGE: %{public}@", log: log, type: .info, stage)
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 清除上次的错误 / 阶段记录
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelError)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelErrorTime)
        sharedDefaults?.set("init_logger", forKey: Constants.AppGroupKey.tunnelStage)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: Constants.AppGroupKey.tunnelStageTime)
        sharedDefaults?.synchronize()
        startCompletionCalled = false
        easytierReady = false

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

        // === 阶段 1：初始化日志 ===
        // 修复：原代码 `if ret != 0, let msg = errMsg` 在 errMsg==nil 时不调用 completionHandler，
        // 导致 iOS 系统超时取消且无错误信息。改为：只要 ret != 0 就报错。
        var errMsg: UnsafePointer<CChar>? = nil
        let ret = rust_init_logger(logPath, "info", "CraftLink", &errMsg)
        if ret != 0 {
            let errorMsg = errMsg.map { String(cString: $0) } ?? "(Rust 未提供错误信息)"
            if let msg = errMsg { rust_free_string(msg) }
            callCompletion(completionHandler, error: reportError("日志初始化失败: \(errorMsg)", code: -1))
            return
        }

        let inviteCode = sharedDefaults?.string(forKey: Constants.AppGroupKey.currentInviteCode) ?? ""
        let isServer = sharedDefaults?.bool(forKey: Constants.AppGroupKey.isServer) ?? false
        let port = sharedDefaults?.string(forKey: Constants.AppGroupKey.currentPort) ?? ""
        // 优先读主 App 写入的 networkName/networkSecret/hostname（Scaffolding-MC 协议）
        var networkName = sharedDefaults?.string(forKey: Constants.AppGroupKey.networkName) ?? ""
        var networkSecret = sharedDefaults?.string(forKey: Constants.AppGroupKey.networkSecret) ?? ""
        let hostname = sharedDefaults?.string(forKey: Constants.AppGroupKey.hostname) ?? ""
        // 兼容 fallback：主 App 没写时从邀请码计算（旧逻辑）
        if networkName.isEmpty && !inviteCode.isEmpty {
            networkName = inviteCode.uppercased()
                .replacingOccurrences(of: "U/", with: "")
                .replacingOccurrences(of: "-", with: "")
        }
        if networkSecret.isEmpty {
            networkSecret = networkName
        }

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

        // === 阶段 2：setTunnelNetworkSettings + 取 TUN fd ===
        // 关键修复：EasyTier 的 run_network_instance 在公网 peer 不可达时会阻塞等待，
        // 原 startTunnel completionHandler 一直不被调用 → iOS 系统约 30-60 秒超时取消
        // → 状态变 disconnected 但无 tunnelError（因为是系统取消，不是 PacketTunnel 报错）。
        // 修复策略：TUN 就绪 + 取到 fd 后立即 completionHandler(nil) 让 iOS 进入 connected，
        // 然后 easytierQueue 异步启动 EasyTier；失败时 cancelTunnelWithError 主动取消。
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.callCompletion(completionHandler, error: self.reportError("VPN 网络配置失败: \(error.localizedDescription)", code: -5))
                return
            }

            // 用 keyPath "socket.fileDescriptor" 获取 TUN fd（EasyTier 官方用法）
            var fd: Int32 = -1
            if let raw = try? self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber {
                fd = raw.int32Value
            }
            // 兼容旧版 iOS 的 fallback key
            if fd < 0, let raw = try? self.packetFlow.value(forKeyPath: "socketFileDescriptor") as? NSNumber {
                fd = raw.int32Value
            }
            os_log("TUN fd obtained: %{public}d", log: self.log, type: .info, fd)

            if fd < 0 {
                os_log("Failed to obtain TUN fd from packetFlow", log: self.log, type: .error)
                self.callCompletion(completionHandler, error: self.reportError(
                    "TUN 文件描述符获取失败：iOS 沙盒拒绝访问 packetFlow 私有属性。请确认使用 TrollStore/越狱环境安装，且 iOS 版本为 14.0-16.6.1 或 17.0。",
                    code: -3
                ))
                return
            }

            // TUN 已就绪，立即告诉 iOS 启动成功（状态变 connected），EasyTier 后台启动。
            // 这样可以避免 EasyTier 连公网 peer 阻塞导致 iOS 超时取消 tunnel。
            self.reportStage("tun_ready")
            self.callCompletion(completionHandler, error: nil)

            // === 阶段 3：异步启动 EasyTier ===
            self.easytierQueue.async {
                self.startEasytierAsync(fd: fd, networkName: networkName, networkSecret: networkSecret, hostname: hostname)
            }
        }
    }

    /// 异步启动 EasyTier 网络实例。成功上报 `ready`，失败主动 `cancelTunnelWithError`。
    private func startEasytierAsync(fd: Int32, networkName: String, networkSecret: String, hostname: String) {
        reportStage("easytier_starting")

        // 构建 TOML 配置（network_name/secret 拆分，房主带 hostname）
        var tomlLines = [
            "instance_name = \"craftlink\"",
            "network_name = \"\(networkName)\"",
            "shared_key = \"\(networkSecret)\"",
            "listen_port = 0",
            "peers = [",
            "  \"tcp://public.easytier.cn:11010\",",
            "  \"udp://public.easytier.cn:11010\"",
            "]",
            "enable_ipv6 = false"
        ]
        if !hostname.isEmpty {
            tomlLines.insert("hostname = \"\(hostname)\"", at: 1)
        }
        let tomlConfig = tomlLines.joined(separator: "\n")
        os_log("EasyTier TOML:\n%{public}@", log: log, type: .info, tomlConfig)

        // 启动网络实例（修复：ret != 0 时无论 errMsg 是否为 nil 都要报错）
        var cfgErrMsg: UnsafePointer<CChar>? = nil
        let runRet = rust_run_network_instance(tomlConfig, &cfgErrMsg)
        if runRet != 0 {
            let errorMsg = cfgErrMsg.map { String(cString: $0) } ?? "(Rust 未提供错误信息，可能 TOML 配置解析失败)"
            if let msg = cfgErrMsg { rust_free_string(msg) }
            os_log("run_network_instance failed: %{public}@", log: log, type: .error, errorMsg)
            let err = reportError("EasyTier 网络实例启动失败: \(errorMsg)", code: -2)
            // iOS 已认为 connected，需主动取消让状态变 disconnected
            cancelTunnelWithError(err)
            return
        }

        // 传入系统 TUN fd 给 EasyTier
        var fdErrMsg: UnsafePointer<CChar>? = nil
        let fdRet = rust_set_tun_fd(fd, &fdErrMsg)
        if fdRet != 0 {
            let errorMsg = fdErrMsg.map { String(cString: $0) } ?? "(Rust 未提供错误信息)"
            if let msg = fdErrMsg { rust_free_string(msg) }
            _ = rust_stop_network_instance()
            os_log("set_tun_fd failed: %{public}@", log: log, type: .error, errorMsg)
            let err = reportError("TUN FD 设置失败: \(errorMsg)", code: -4)
            cancelTunnelWithError(err)
            return
        }
        os_log("TUN FD set successfully: %{public}d", log: log, type: .info, fd)
        easytierReady = true
        reportStage("ready")
    }

    /// 防止 startTunnel completionHandler 被重复调用（异步路径可能引发）。
    private func callCompletion(_ completion: @escaping (Error?) -> Void, error: Error?) {
        if startCompletionCalled { return }
        startCompletionCalled = true
        completion(error)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let result = rust_stop_network_instance()
        os_log("Rust network instance stopped with result: %{public}d (reason: %{public}@)",
               log: log, type: .info, result, String(describing: reason))
        // 清理阶段标记
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelStage)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelStageTime)
        sharedDefaults?.synchronize()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            os_log("Received app message: %{public}@", log: log, type: .info, message)
        }
        completionHandler?(nil)
    }
}
