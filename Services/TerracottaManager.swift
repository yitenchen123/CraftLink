import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - TerracottaManager
//
// 替代旧版 `VPNManager`。区别：
//   - 不再使用 `NETunnelProviderManager` / `NEPacketTunnelProvider` → 不需要 NE 权限。
//   - 不再调用 EasyTier 的 `run_network_instance` / `set_tun_fd`，改为通过
//     `TerracottaBridge` 调用 `terracotta_ios_*` C ABI。
//   - 不再维护 ScaffoldingServer / ScaffoldingClient Swift 实现，Terracotta Rust 侧
//     全权负责 Scaffolding 协议、EasyTier 配置和 port_forward。
//   - 房主/访客的状态都通过 0.5 秒一次的 `terracotta_ios_get_state` 轮询获得，由
//     `TerracottaState` 驱动 UI。
//   - 用 `SilentAudioPlayer` 在房间运行期间提供后台保活。

/// 给 UI 显示的高层状态机。
enum TerracottaStatus: String {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case error = "出错"
}

// 注：玩家角色（房主/加入者）复用 `RoomRole` 枚举（定义在 Models/RoomHistory.swift），
// 因为 RoomHistory 写入 UserDefaults 时需要 Codable，统一类型避免来回转换。

final class TerracottaManager: ObservableObject {

    static let shared = TerracottaManager()

    // MARK: - 给 UI 的 @Published 状态

    /// 高层连接状态（disconnected / connecting / connected / error）。
    @Published private(set) var status: TerracottaStatus = .disconnected
    /// 当前角色（房主/加入者/nil）。
    @Published private(set) var currentRole: RoomRole?
    /// 当前邀请码（房主 hostOk 后才有；访客 joinRoom 后立即写入）。
    @Published private(set) var currentInviteCode: String?
    /// 当前 MC 端口（房主 createRoom 时用户输入；访客 guestOk 后从 url 解析）。
    @Published private(set) var currentPort: String?
    /// 当前阶段中文描述（来自 TerracottaState.localizedStage）。
    @Published private(set) var stageDescription: String = ""
    /// 房间内玩家列表（hostOk/guestOk 时由 Rust 侧 profiles 填充）。
    @Published private(set) var players: [TerracottaPlayerProfile] = []
    /// 访客在 MC 直连用的 `host:port` 字符串（如 "127.0.0.1:25565"）。
    @Published private(set) var directConnectURL: String?
    /// 最近一次错误信息（status=.error 时显示）。
    @Published private(set) var lastError: String?

    // MARK: - 内部状态

    /// Terracotta C ABI 是否已 `start`（App 启动时调一次）。
    private var initialized = false
    /// 上一次轮询到的 `TerracottaState`，用于避免重复发布。
    private var lastState: TerracottaState?
    /// 轮询定时器。
    private var pollTimer: Timer?
    /// 当前是否处于 active session（用于 stop 时知道要不要切回 waiting）。
    private var sessionActive = false

    private init() {
        initializeTerracotta()
    }

    // MARK: - 初始化

    /// 在 App 启动时调用一次，初始化 Terracotta Rust 侧。
    private func initializeTerracotta() {
        guard !initialized else { return }

        let fm = FileManager.default
        // workingDirectory：用 App 的 Documents 目录，machine-id 会写在这里。
        let workDir = (try? fm.url(for: .documentDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))?.path
            ?? NSTemporaryDirectory()

        // 日志路径：写到 Documents/terracotta.log
        let logPath = (try? fm.url(for: .documentDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))?
            .appendingPathComponent("terracotta.log").path

        let ok = TerracottaBridge.start(workingDirectory: workDir, loggingPath: logPath)
        if !ok {
            NSLog("[TerracottaManager] terracotta_ios_start 失败")
            lastError = "Terracotta 初始化失败"
            status = .error
        } else {
            NSLog("[TerracottaManager] Terracotta 已初始化，workDir=\(workDir)")
            initialized = true
        }
    }

    // MARK: - 公开 API

    /// 房主：创建房间（开始扫描本地 MC 的「对局域网开放」）。
    /// - Parameters:
    ///   - inviteCode: 当前 `CreateRoomView` 生成的邀请码（用于复用）。可传 nil 让 Rust 侧生成。
    ///   - port: 仅用于 UI 显示和 RoomHistory，不传给 Terracotta（Terracotta 自己会从 LAN
    ///     广播里发现 MC 端口）。
    ///   - playerName: 玩家昵称，nil 用设备名。
    ///   - completion: 调用后立即返回 nil（实际启动是异步的，UI 通过 `status` / `stageDescription` 观察）。
    func createRoom(inviteCode: String?, port: String?, playerName: String?, completion: @escaping (Error?) -> Void) {
        guard initialized else {
            completion(terracottaError("Terracotta 未初始化"))
            return
        }

        // 重置上一次 session 残留
        resetSessionState()

        currentRole = .host
        currentInviteCode = inviteCode
        currentPort = port
        status = .connecting
        stageDescription = "正在扫描本地 Minecraft 服务器..."
        sessionActive = true

        // 启动后台保活
        SilentAudioPlayer.shared.startKeepingAlive()

        // 调用 Rust：开始 host scanning
        // 注：传入 inviteCode 让 Rust 侧复用同一邀请码；playerName 透传。
        TerracottaBridge.setScanning(room: inviteCode, playerName: playerName)

        startPolling()
        completion(nil)
    }

    /// 访客：加入房间。
    /// - Parameters:
    ///   - inviteCode: 必填，房主分享的 Scaffolding 邀请码。
    ///   - playerName: 玩家昵称，nil 用设备名。
    ///   - completion: 返回错误（如邀请码非法、当前不在 Waiting 状态）。
    func joinRoom(inviteCode: String, playerName: String?, completion: @escaping (Error?) -> Void) {
        guard initialized else {
            completion(terracottaError("Terracotta 未初始化"))
            return
        }

        // 先用 Rust 侧校验邀请码（base-34 + mod-7 校验）
        guard TerracottaBridge.verifyRoomCode(inviteCode) else {
            let err = terracottaError("邀请码格式错误（应为 U/NNNN-NNNN-SSSS-SSSS）")
            lastError = err.localizedDescription
            completion(err)
            return
        }

        // 重置上一次 session 残留
        resetSessionState()

        currentRole = .client
        currentInviteCode = inviteCode
        status = .connecting
        stageDescription = "正在连接房主..."
        sessionActive = true

        // 启动后台保活
        SilentAudioPlayer.shared.startKeepingAlive()

        // 调用 Rust：开始 guest
        let ok = TerracottaBridge.setGuesting(room: inviteCode, playerName: playerName)
        if !ok {
            let err = terracottaError("加入失败：邀请码无效或 Terracotta 不在 Waiting 状态")
            lastError = err.localizedDescription
            status = .error
            sessionActive = false
            SilentAudioPlayer.shared.stopKeepingAlive()
            completion(err)
            return
        }

        startPolling()
        completion(nil)
    }

    /// 关闭当前会话（房主关房 / 访客断开）。Idempotent。
    func stopVPN() {
        guard sessionActive else { return }
        sessionActive = false

        // 让 Rust 侧回到 Waiting（会终止 EasyTier 实例、清理 Scaffolding 连接）
        TerracottaBridge.setWaiting()
        stopPolling()

        // 停止后台保活
        SilentAudioPlayer.shared.stopKeepingAlive()

        // 重置 UI 状态
        DispatchQueue.main.async {
            self.status = .disconnected
            self.currentRole = nil
            self.currentInviteCode = nil
            self.currentPort = nil
            self.stageDescription = ""
            self.players = []
            self.directConnectURL = nil
            self.lastError = nil
            self.lastState = nil
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // 立即跑一次，加速首次状态更新
        pollOnce()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        guard let state = TerracottaBridge.pollState() else { return }
        // 跳过未变化的状态（避免无谓的 @Published 触发）
        if state == lastState { return }
        lastState = state

        DispatchQueue.main.async {
            self.applyState(state)
        }
    }

    /// 把 Rust 侧的 `TerracottaState` 映射到 UI 状态。
    private func applyState(_ state: TerracottaState) {
        stageDescription = state.localizedStage

        switch state {
        case .waiting:
            // 异常回到 waiting（如 Rust 侧出错后自动重置）
            if sessionActive {
                status = .disconnected
                sessionActive = false
                SilentAudioPlayer.shared.stopKeepingAlive()
                stopPolling()
            }

        case .hostScanning:
            status = .connecting
            players = []

        case .hostStarting(_, let room):
            status = .connecting
            // Rust 侧生成的邀请码（如果 createRoom 时传了 nil）
            if currentInviteCode == nil {
                currentInviteCode = room
            }

        case .hostOk(_, let room, _, let profiles):
            status = .connected
            if currentInviteCode == nil {
                currentInviteCode = room
            }
            players = profiles
            lastError = nil

        case .guestConnecting:
            status = .connecting
            players = []

        case .guestStarting:
            status = .connecting

        case .guestOk(_, let url, _, let profiles):
            status = .connected
            directConnectURL = url
            // 从 url（如 "127.0.0.1:25565"）解析端口写入 currentPort
            if let port = url.split(separator: ":").last {
                currentPort = String(port)
            }
            players = profiles
            lastError = nil

        case .exception(_, let type):
            status = .error
            lastError = TerracottaBridge.describeException(type)
            // 异常后保持轮询，让 Rust 侧可能的自愈（set_waiting）能反映到 UI
        }
    }

    // MARK: - Helpers

    private func resetSessionState() {
        lastError = nil
        stageDescription = ""
        players = []
        directConnectURL = nil
        lastState = nil
        // 如果上一次 session 还在跑（异常情况），先回到 Waiting
        if sessionActive {
            TerracottaBridge.setWaiting()
        }
    }

    private func terracottaError(_ message: String) -> Error {
        NSError(domain: "CraftLink", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
