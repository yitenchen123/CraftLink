import Foundation
import Network
import Combine
import OSLog

/// Scaffolding-MC 协议客户端（访客端）。
///
/// 职责：
/// 1. 连接到房主虚拟 IP（默认 `10.0.0.1`）的 MC 端口
/// 2. 连接成功后立即发 `c:server_port` 获取 MC 服务器端口
/// 3. 协商 `c:protocols`
/// 4. 每 5 秒发 `c:player_ping` 心跳，并在响应里同步玩家列表
/// 5. 暴露 `@Published` 状态：连接状态、MC 端口、玩家列表、错误
///
/// 与 HMCL/FCL 房主互通：访客连接房主 `10.0.0.1:{mc_port}` 即可，
/// 端口需房主额外告知（邀请码不含端口信息）。
@available(iOS 14.0, *)
public final class ScaffoldingClient: ObservableObject {

    public enum State: String {
        case disconnected = "未连接"
        case connecting = "连接中"
        case connected = "已连接"
        case failed = "连接失败"
    }

    @Published public private(set) var state: State = .disconnected
    @Published public private(set) var mcPort: UInt16?
    @Published public private(set) var players: [PlayerProfile] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var negotiatedProtocols: [String] = []

    /// 房主虚拟 IP（默认 `10.0.0.1`）。
    public let hostIP: String
    /// 房主 Scaffolding 协议端口（= MC 局域网端口）。
    public let port: UInt16
    /// 本机玩家档案（kind 强制为 `GUEST`）。
    public let localProfile: PlayerProfile

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.craftlink.scaffolding.client")
    private let log = OSLog(subsystem: "com.craftlink", category: "ScaffoldingClient")
    private let decoder = ScaffoldingFrameDecoder(mode: .response)
    private var heartbeatTimer: DispatchSourceTimer?
    private var pendingProtocolsRequest = false

    public init(hostIP: String, port: UInt16, localProfile: PlayerProfile) {
        self.hostIP = hostIP
        self.port = port
        var p = localProfile
        p.kind = .guest
        self.localProfile = p
    }

    /// 连接房主并启动协议握手。
    public func connect() {
        disconnect()
        DispatchQueue.main.async { self.state = .connecting; self.lastError = nil }
        let host = NWEndpoint.Host(hostIP)
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async {
                self.state = .failed
                self.lastError = "无效端口 \(self.port)"
            }
            return
        }
        let conn = NWConnection(host: host, port: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                os_log("Client connected to %{public}@:%d", log: self.log, type: .info, self.hostIP, Int(self.port))
                DispatchQueue.main.async { self.state = .connected; self.lastError = nil }
                self.startReceiving()
                self.sendInitialRequests()
                self.startHeartbeat()
            case .failed(let err):
                os_log("Client failed: %{public}@", log: self.log, type: .error, err.localizedDescription)
                DispatchQueue.main.async {
                    self.state = .failed
                    self.lastError = err.localizedDescription
                }
            case .cancelled:
                DispatchQueue.main.async { self.state = .disconnected }
            default:
                break
            }
        }
        conn.start(queue: queue)
        self.connection = conn
    }

    public func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        decoder.reset()
        pendingProtocolsRequest = false
        DispatchQueue.main.async {
            self.state = .disconnected
            self.mcPort = nil
            self.players = []
            self.negotiatedProtocols = []
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.decoder.feed(data)
                self.processResponses()
            }
            if let error = error {
                DispatchQueue.main.async {
                    self.state = .failed
                    self.lastError = "接收数据失败：\(error.localizedDescription)"
                }
                return
            }
            if isComplete {
                DispatchQueue.main.async {
                    self.state = .disconnected
                    self.lastError = "房主关闭了连接"
                }
                return
            }
            self.startReceiving()
        }
    }

    private func processResponses() {
        while !decoder.completedResponses.isEmpty {
            let resp = decoder.completedResponses.removeFirst()
            handleResponse(resp)
        }
    }

    /// 按响应 body 特征分发：
    /// - body.count == 2 且 status==ok 且 mcPort==nil：当作 `c:server_port` 响应
    /// - body 首字节是 `[` 且能解析为 [PlayerProfile]：当作玩家列表更新
    /// - body 是 `\0` 分割串：当作 `c:protocols` 响应
    /// - 其他：忽略（c:ping echo 等）
    private func handleResponse(_ resp: ScaffoldingResponse) {
        if resp.status != ScaffoldingStatusCode.ok.rawValue {
            let msg = String(data: resp.body, encoding: .utf8) ?? "<二进制错误>"
            os_log("Server error status=%d: %{public}@", log: log, type: .error, Int(resp.status), msg)
            DispatchQueue.main.async { self.lastError = "房主返回错误(\(resp.status))：\(msg)" }
            return
        }
        let body = resp.body
        if body.isEmpty { return }

        // c:server_port：2 字节大端 u16
        if body.count == 2 && mcPort == nil {
            let port = body.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            DispatchQueue.main.async { self.mcPort = port }
            os_log("Got mcPort=%d", log: log, type: .info, Int(port))
            return
        }

        // c:protocols：\0 分割串
        if pendingProtocolsRequest {
            let protos = ScaffoldingProtocolListCodec.decode(body)
            let negotiated = ScaffoldingProtocolListCodec.intersect(
                ScaffoldingProtocolType.supportedProtocols, protos)
            DispatchQueue.main.async { self.negotiatedProtocols = negotiated }
            pendingProtocolsRequest = false
            os_log("Negotiated protocols: %{public}@", log: log, type: .info, negotiated.joined(separator: ","))
            // 协议列表也可能是空 body，直接 return
            if protos.isEmpty || body.first == 0x00 { return }
        }

        // c:player_profiles_list：JSON 数组（首字节 `[`）
        if body.first == 0x5B { // '['
            do {
                let list = try JSONDecoder().decode([PlayerProfile].self, from: body)
                DispatchQueue.main.async { self.players = list }
            } catch {
                os_log("Decode players failed: %{public}@", log: log, type: .error, error.localizedDescription)
            }
        }
    }

    // MARK: - Sending

    private func sendInitialRequests() {
        // 1. 询问 MC 端口
        send(request: ScaffoldingRequest(type: ScaffoldingProtocolType.serverPort))
        // 2. 协商协议
        pendingProtocolsRequest = true
        send(request: ScaffoldingRequest(type: ScaffoldingProtocolType.protocols))
        // 3. 立即发一次心跳，让房主尽快把自己加入玩家列表
        sendPlayerPing()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.sendPlayerPing()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendPlayerPing() {
        do {
            let data = try JSONEncoder().encode(localProfile)
            send(request: ScaffoldingRequest(type: ScaffoldingProtocolType.playerPing, body: data))
        } catch {
            os_log("Encode player_ping failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    private func send(request: ScaffoldingRequest) {
        let payload = request.encode()
        connection?.send(content: payload, completion: .contentProcessed { error in
            if let error = error {
                os_log("Send %{public}@ failed: %{public}@",
                       log: self.log, type: .error, request.type, error.localizedDescription)
            }
        })
    }
}
