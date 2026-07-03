import Foundation
import Network
import Combine
import OSLog

/// Minecraft Java 版局域网开放检测器。
///
/// 当玩家在 MC 内点「对局域网开放」时，MC 客户端会向多播地址
/// `224.0.2.60:4445` 发送一个 MOTD 数据包，格式：
/// ```
/// [MOTD]<玩家自定义的欢迎词>[/MOTD][AD]<本地端口号>[/AD]
/// ```
/// 例：`[MOTD]My World[/MOTD][AD]49152[/AD]`
///
/// 监听该多播即可让房主 App 自动感知"自己开了局域网"以及"MC 分配的端口"，
/// 无需用户在 CreateRoomView 手填端口号。
///
/// - Note: 该多播地址是 MC Java 版约定，与 Bonjour/mDNS 无关。
@available(iOS 14.0, *)
public final class MinecraftLANDiscovery: ObservableObject {

    public struct LANRoom: Identifiable, Equatable {
        public let id = UUID()
        public let motd: String
        public let port: UInt16
        public let host: String?      // 发包方 IP（用于日志，可为 nil）
        public let detectedAt: Date
    }

    @Published public private(set) var rooms: [LANRoom] = []
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var lastError: String?

    /// MC 多播地址与端口（硬编码约定，不可配置）。
    public static let multicastHost = "224.0.2.60"
    public static let multicastPort: NWEndpoint.Port = 4445

    private var listener: NWConnection?
    private let queue = DispatchQueue(label: "com.craftlink.mc-lan-discovery")
    private let log = OSLog(subsystem: "com.craftlink", category: "MCLANDiscovery")

    public init() {}

    /// 开始监听 MC 局域网多播。重复调用安全（会先停止旧监听）。
    public func start() {
        stop()
        let params = NWParameters.udp
        // 允许在 VPN 隧道接口上也收到多播（重要：本 App 自身就在 VPN 内）
        params.allowLocalEndpointReuse = true
        let host = NWEndpoint.Host(MinecraftLANDiscovery.multicastHost)
        let port = MinecraftLANDiscovery.multicastPort
        let conn = NWConnection(host: host, port: port, using: params)
        self.listener = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                os_log("MC LAN listener ready", log: self.log, type: .info)
                DispatchQueue.main.async { self.isListening = true; self.lastError = nil }
                self.receiveLoop()
            case .failed(let err):
                os_log("MC LAN listener failed: %{public}@", log: self.log, type: .error, err.localizedDescription)
                DispatchQueue.main.async {
                    self.isListening = false
                    self.lastError = err.localizedDescription
                }
            case .cancelled:
                DispatchQueue.main.async { self.isListening = false }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.isListening = false }
    }

    /// 清空已检测到的房间列表（用于房主开新房间前重置）。
    public func clearRooms() {
        DispatchQueue.main.async { self.rooms = [] }
    }

    // MARK: - Private

    private func receiveLoop() {
        listener?.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                os_log("MC LAN receive error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
                return
            }
            if let data = data, !data.isEmpty,
               let msg = String(data: data, encoding: .utf8) {
                self.handleMulticastMessage(msg)
            }
            self.receiveLoop()
        }
    }

    /// 解析 `[MOTD]...[/MOTD][AD]<port>[/AD]` 格式，提取端口与 MOTD。
    private func handleMulticastMessage(_ message: String) {
        // 容错：MC 偶尔会先发 [AD] 后发 [MOTD]，用正则分别提取
        guard let port = extractPort(from: message) else {
            os_log("MC LAN message without [AD] port: %{public}@", log: log, type: .debug, message)
            return
        }
        let motd = extractMOTD(from: message) ?? "Minecraft LAN World"

        let room = LANRoom(motd: motd,
                           port: port,
                           host: nil,
                           detectedAt: Date())
        DispatchQueue.main.async {
            // 去重：同端口只保留最新
            self.rooms.removeAll { $0.port == port }
            self.rooms.insert(room, at: 0)
            // 房主侧只关心最近一个房间；列表上限保留 10 条
            if self.rooms.count > 10 { self.rooms.removeLast() }
        }
        os_log("MC LAN detected: motd=%{public}@ port=%{public}d",
               log: log, type: .info, motd, port)
    }

    private func extractPort(from message: String) -> UInt16? {
        guard let range = message.range(of: #"\[AD\](\d+)\[/AD\]"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(message[range])
        // 提取数字部分
        let digits = matched.filter { $0.isNumber }
        return UInt16(digits)
    }

    private func extractMOTD(from message: String) -> String? {
        guard let range = message.range(of: #"\[MOTD\](.*?)\[/MOTD\]"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(message[range])
        return matched
            .replacingOccurrences(of: "[MOTD]", with: "")
            .replacingOccurrences(of: "[/MOTD]", with: "")
    }
}
