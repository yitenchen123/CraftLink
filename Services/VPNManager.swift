import NetworkExtension
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
    /// 当前房间内的玩家列表（房主由 ScaffoldingServer 维护，访客由 ScaffoldingClient 同步）。
    @Published var players: [PlayerProfile] = []
    /// 访客已发现的房主 MC 端口（由 ScaffoldingClient 通过 `c:server_port` 获取）。
    @Published var discoveredMCPort: UInt16?
    /// PacketTunnel 上报的启动阶段原始值（init_logger / tun_ready / easytier_starting / ready / failed）。
    @Published var tunnelStage: String?
    /// 给 UI 显示的中文阶段描述。
    @Published var stageDescription: String = ""

    // 关键修复：用 NETunnelProviderManager 代替 NEVPNManager
    // NEVPNManager 用于系统 VPN（IKEv2/IPSec），管理自定义 PacketTunnelProvider
    // 必须用 NETunnelProviderManager，否则 startTunnel 会被系统拒绝
    private var tunnelManager: NETunnelProviderManager?
    private let sharedDefaults = UserDefaults(suiteName: Constants.appGroupId)

    /// 房主端 Scaffolding 协议服务器。
    private var scaffoldingServer: ScaffoldingServer?
    /// 访客端 Scaffolding 协议客户端。
    private var scaffoldingClient: ScaffoldingClient?
    /// 访客要连接的房主 MC 端口（用于建立 ScaffoldingClient TCP 连接）。
    private var hostPort: UInt16?
    /// Combine 订阅 bag。
    private var cancellables = Set<AnyCancellable>()
    /// 轮询 PacketTunnel 阶段的定时器（仅在 connecting/connected 状态下运行）。
    private var stageTimer: Timer?
    /// 标记 EasyTier 是否已就绪，避免重复触发 ScaffoldingClient 启动。
    private var easytierReadyHandled = false

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
            stopStageTimer()
            return
        }
        switch connection.status {
        case .disconnected:
            status = .disconnected
            stopStageTimer()
            // 读取 PacketTunnel 写回的具体错误信息
            if let tunnelErr = sharedDefaults?.string(forKey: Constants.AppGroupKey.tunnelError),
               !tunnelErr.isEmpty {
                DispatchQueue.main.async {
                    self.lastError = tunnelErr
                }
            }
        case .connecting:
            status = .connecting
            startStageTimer()
        case .connected:
            status = .connected
            lastError = nil
            // 不再立即启动 ScaffoldingClient：EasyTier 此时可能还在异步启动中（PacketTunnel
            // 已 completionHandler(nil) 让 iOS 进入 connected，但虚拟网络可能尚未真正通）。
            // 由 pollStage 在 stage=="ready" 时触发 startScaffoldingIfNeeded。
            startStageTimer()
            // 立即轮询一次，加速 stage 已就绪时的响应
            pollStage()
        case .disconnecting:
            status = .disconnecting
            stopStageTimer()
        case .invalid:
            status = .disconnected
            stopStageTimer()
        case .reasserting:
            status = .connecting
            startStageTimer()
        @unknown default:
            status = .disconnected
            stopStageTimer()
        }
    }

    // MARK: - 阶段轮询

    /// 启动 0.5 秒间隔的 stage 轮询 timer。
    private func startStageTimer() {
        if stageTimer != nil { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollStage()
        }
        RunLoop.main.add(timer, forMode: .common)
        stageTimer = timer
        // 立即跑一次
        pollStage()
    }

    private func stopStageTimer() {
        stageTimer?.invalidate()
        stageTimer = nil
    }

    /// 读 App Group 的 tunnelStage，更新 UI 阶段描述；stage=ready 时启动 ScaffoldingClient。
    private func pollStage() {
        let stage = sharedDefaults?.string(forKey: Constants.AppGroupKey.tunnelStage)
        if stage != tunnelStage {
            tunnelStage = stage
            stageDescription = describeStage(stage)
        }

        // EasyTier 就绪 → 启动访客 ScaffoldingClient（仅一次）
        if stage == "ready", !easytierReadyHandled {
            easytierReadyHandled = true
            startScaffoldingIfNeeded()
        }

        // 失败阶段 → 同步错误信息到 lastError
        if let stage = stage, stage.hasPrefix("failed") {
            if let err = sharedDefaults?.string(forKey: Constants.AppGroupKey.tunnelError),
               !err.isEmpty {
                lastError = err
            }
        }
    }

    /// 把 PacketTunnel 上报的阶段原始值翻译成中文描述。
    private func describeStage(_ stage: String?) -> String {
        guard let stage = stage else { return "" }
        switch stage {
        case "init_logger": return "正在初始化日志系统..."
        case "tun_ready": return "虚拟网卡已就绪，正在启动 EasyTier..."
        case "easytier_starting": return "正在启动 EasyTier 网络实例..."
        case "ready": return "虚拟网络已就绪"
        default:
            return stage.hasPrefix("failed") ? "启动失败" : ""
        }
    }

    func createRoom(inviteCode: String, port: String, completion: @escaping (Error?) -> Void) {
        configureAndStart(inviteCode: inviteCode, port: port, isServer: true, hostPort: nil, completion: completion)
    }

    func joinRoom(inviteCode: String, completion: @escaping (Error?) -> Void) {
        configureAndStart(inviteCode: inviteCode, port: nil, isServer: false, hostPort: nil, completion: completion)
    }

    /// 加入房间（指定房主 MC 端口，用于建立 Scaffolding 协议连接）。
    /// - Parameters:
    ///   - inviteCode: Scaffolding-MC 邀请码
    ///   - hostPort: 房主 MC 端口（= Scaffolding 协议端口）。nil 时仅建立 VPN，不启动协议客户端。
    func joinRoom(inviteCode: String, hostPort: UInt16?, completion: @escaping (Error?) -> Void) {
        configureAndStart(inviteCode: inviteCode, port: nil, isServer: false, hostPort: hostPort, completion: completion)
    }

    private func configureAndStart(inviteCode: String, port: String?, isServer: Bool, hostPort: UInt16?, completion: @escaping (Error?) -> Void) {
        // 1. 校验邀请码（Scaffolding-MC 标准格式 + 被 7 整除校验）
        guard let parsed = ScaffoldingInviteCode.parse(inviteCode) else {
            let error = NSError(domain: "CraftLink", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "邀请码格式错误（应为 U/NNNN-NNNN-SSSS-SSSS）"])
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                completion(error)
            }
            return
        }

        // 2. 房主模式校验端口
        var mcPort: UInt16? = nil
        if isServer {
            guard let portStr = port, let p = UInt16(portStr), p > 0 else {
                let error = NSError(domain: "CraftLink", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "请输入有效的 Minecraft 端口（1-65535）"])
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    completion(error)
                }
                return
            }
            mcPort = p
        }

        // 清理上一次会话残留的 Scaffolding 协议层（避免重复 join 时旧 client 阻止新连接）
        scaffoldingServer?.stop()
        scaffoldingServer = nil
        scaffoldingClient?.disconnect()
        scaffoldingClient = nil
        cancellables.removeAll()
        players = []
        discoveredMCPort = nil
        easytierReadyHandled = false
        tunnelStage = nil
        stageDescription = ""

        currentInviteCode = inviteCode
        currentPort = port
        currentRole = isServer ? .host : .client
        self.hostPort = hostPort

        // 3. 写入 App Group，供 PacketTunnel 读取 EasyTier 配置
        sharedDefaults?.set(inviteCode, forKey: Constants.AppGroupKey.currentInviteCode)
        sharedDefaults?.set(port ?? "", forKey: Constants.AppGroupKey.currentPort)
        sharedDefaults?.set(isServer, forKey: Constants.AppGroupKey.isServer)
        sharedDefaults?.set(parsed.networkName, forKey: Constants.AppGroupKey.networkName)
        sharedDefaults?.set(parsed.networkSecret, forKey: Constants.AppGroupKey.networkSecret)
        if isServer, let mcPort = mcPort {
            // 房主 hostname = scaffolding-mc-server-{port}，供 EasyTier 网络内识别联机中心
            let hostname = ScaffoldingInviteCode.serverHostname(mcPort: mcPort)
            sharedDefaults?.set(hostname, forKey: Constants.AppGroupKey.hostname)
            sharedDefaults?.set(Int(mcPort), forKey: Constants.AppGroupKey.mcPort)
        } else {
            sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.hostname)
            sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.mcPort)
        }
        sharedDefaults?.synchronize()

        // 4. 房主：立即启动 ScaffoldingServer（监听 MC 端口，bind 到所有接口）
        //    访客：等 VPN connected 后在 startScaffoldingIfNeeded() 中启动 ScaffoldingClient
        if isServer, let mcPort = mcPort {
            startHostScaffoldingServer(mcPort: mcPort)
        }

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
                            if let tunnelErr = self.sharedDefaults?.string(forKey: Constants.AppGroupKey.tunnelError),
                               !tunnelErr.isEmpty {
                                self.lastError = tunnelErr
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scaffolding 协议层生命周期

    /// 房主：启动 ScaffoldingServer 并订阅玩家列表。
    private func startHostScaffoldingServer(mcPort: UInt16) {
        scaffoldingServer?.stop()
        let hostProfile = PlayerProfile(
            name: deviceDisplayName(),
            machineId: PlayerProfileUtil.stableMachineId(),
            vendor: Constants.vendor,
            kind: .host
        )
        let server = ScaffoldingServer(port: mcPort, hostProfile: hostProfile)
        server.$players
            .receive(on: DispatchQueue.main)
            .assign(to: \.players, on: self)
            .store(in: &cancellables)
        server.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                if let err = err { self?.lastError = err }
            }
            .store(in: &cancellables)
        server.start()
        scaffoldingServer = server
    }

    /// 访客：VPN 连接成功后启动 ScaffoldingClient 连接房主 10.0.0.1:{hostPort}。
    private func startScaffoldingIfNeeded() {
        guard currentRole == .client, scaffoldingClient == nil, let port = hostPort else { return }
        let guestProfile = PlayerProfile(
            name: deviceDisplayName(),
            machineId: PlayerProfileUtil.stableMachineId(),
            vendor: Constants.vendor,
            kind: .guest
        )
        let client = ScaffoldingClient(hostIP: Constants.serverIP, port: port, localProfile: guestProfile)
        client.$players
            .receive(on: DispatchQueue.main)
            .assign(to: \.players, on: self)
            .store(in: &cancellables)
        client.$mcPort
            .receive(on: DispatchQueue.main)
            .assign(to: \.discoveredMCPort, on: self)
            .store(in: &cancellables)
        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                if let err = err { self?.lastError = err }
            }
            .store(in: &cancellables)
        client.connect()
        scaffoldingClient = client
    }

    /// 用于 PlayerProfile.name 的设备显示名。
    private func deviceDisplayName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    func stopVPN() {
        tunnelManager?.connection.stopVPNTunnel()

        // 停止阶段轮询
        stopStageTimer()

        // 停止 Scaffolding 协议层
        scaffoldingServer?.stop()
        scaffoldingServer = nil
        scaffoldingClient?.disconnect()
        scaffoldingClient = nil
        cancellables.removeAll()
        hostPort = nil
        players = []
        discoveredMCPort = nil
        easytierReadyHandled = false
        tunnelStage = nil
        stageDescription = ""

        currentInviteCode = nil
        currentPort = nil
        currentRole = nil
        lastError = nil

        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.currentInviteCode)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.currentPort)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.isServer)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.networkName)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.networkSecret)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.hostname)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.mcPort)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelError)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelErrorTime)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelStage)
        sharedDefaults?.removeObject(forKey: Constants.AppGroupKey.tunnelStageTime)
        sharedDefaults?.synchronize()
    }
}
