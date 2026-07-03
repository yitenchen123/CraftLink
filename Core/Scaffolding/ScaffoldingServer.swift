import Foundation
import Network
import Combine
import OSLog

/// Scaffolding-MC 协议服务器（房主端）。
///
/// 职责：
/// 1. 在指定端口监听 TCP，接受访客连接
/// 2. 处理 `c:ping` / `c:protocols` / `c:server_port` / `c:player_ping` / `c:player_profiles_list` 请求
/// 3. 维护玩家列表（含房主自己，kind=`HOST`）
/// 4. 每 5 秒清理超过 15 秒未心跳的访客
/// 5. 玩家列表变化时主动向所有连接推送 `c:player_profiles_list` 响应
///
/// 端口约定：监听 MC 局域网端口（与 HMCL/FCL 一致），让访客通过邀请码 + 房主告知的 MC 端口连接。
/// 若该端口被 MC 服务器占用（bind 失败），`start()` 会回调错误，调用方需提示用户。
@available(iOS 14.0, *)
public final class ScaffoldingServer: ObservableObject {

    /// 当前房间内的所有玩家（含房主自己）。
    @Published public private(set) var players: [PlayerProfile] = []

    /// 服务器是否在监听。
    @Published public private(set) var isRunning: Bool = false

    /// 最近一次错误（bind 失败、监听异常等）。
    @Published public private(set) var lastError: String?

    /// 监听端口（= MC 局域网端口）。
    public let port: UInt16

    /// 房主自己的 profile。
    public let hostProfile: PlayerProfile

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.craftlink.scaffolding.server")
    private let log = OSLog(subsystem: "com.craftlink", category: "ScaffoldingServer")

    /// machineId → 活跃连接
    private var connections: [String: NWConnection] = [:]
    /// machineId → 最后心跳时间
    private var lastPing: [String: Date] = [:]
    private var cleanupTimer: DispatchSourceTimer?

    public init(port: UInt16, hostProfile: PlayerProfile) {
        self.port = port
        self.hostProfile = hostProfile
        // 房主自己默认在玩家列表里
        self.players = [hostProfile]
        self.lastPing[hostProfile.machineId] = Date()
    }

    /// 启动监听。重复调用安全。
    public func start() {
        stop()
        do {
            let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
            let listener = try NWListener(using: .tcp, on: endpoint)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    os_log("ScaffoldingServer listening on port %d", log: self.log, type: .info, Int(self.port))
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.lastError = nil
                    }
                    self.startCleanupTimer()
                case .failed(let err):
                    os_log("ScaffoldingServer failed: %{public}@", log: self.log, type: .error, err.localizedDescription)
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.lastError = "监听 \(self.port) 失败：\(err.localizedDescription)"
                    }
                case .cancelled:
                    DispatchQueue.main.async { self.isRunning = false }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
                self.lastError = "端口 \(self.port) 被占用或无权限：\(error.localizedDescription)"
            }
        }
    }

    public func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self = self else { return }
            for (_, conn) in self.connections { conn.cancel() }
            self.connections.removeAll()
            self.lastPing.removeAll()
            // 保留房主自己
            DispatchQueue.main.async {
                self.players = [self.hostProfile]
                self.isRunning = false
            }
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        let decoder = ScaffoldingFrameDecoder(mode: .request)
        receiveLoop(conn: conn, decoder: decoder)
    }

    private func receiveLoop(conn: NWConnection, decoder: ScaffoldingFrameDecoder) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                decoder.feed(data)
                self.processRequests(from: conn, decoder: decoder)
            }
            if let error = error {
                os_log("Server conn error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.removeConnection(conn)
                return
            }
            if isComplete {
                self.removeConnection(conn)
                return
            }
            self.receiveLoop(conn: conn, decoder: decoder)
        }
    }

    private func processRequests(from conn: NWConnection, decoder: ScaffoldingFrameDecoder) {
        while !decoder.completedRequests.isEmpty {
            let req = decoder.completedRequests.removeFirst()
            handleRequest(req, from: conn)
        }
    }

    private func handleRequest(_ req: ScaffoldingRequest, from conn: NWConnection) {
        let response: ScaffoldingResponse
        switch req.type {
        case ScaffoldingProtocolType.ping:
            // echo
            response = .ok(req.body)

        case ScaffoldingProtocolType.protocols:
            response = .ok(ScaffoldingProtocolListCodec.encode(ScaffoldingProtocolType.supportedProtocols))

        case ScaffoldingProtocolType.serverPort:
            response = makeServerPortResponse()

        case ScaffoldingProtocolType.playerPing:
            response = handlePlayerPing(req, from: conn)

        case ScaffoldingProtocolType.playerProfilesList:
            response = makePlayerProfilesResponse()

        default:
            os_log("Unknown protocol type: %{public}@", log: log, type: .error, req.type)
            response = .error("unknown protocol: \(req.type)", code: .invalidRequest)
        }
        send(response, to: conn)
    }

    // MARK: - Protocol handlers

    private func makeServerPortResponse() -> ScaffoldingResponse {
        var portBE = port.bigEndian
        let body = withUnsafeBytes(of: &portBE) { Data($0) }
        return .ok(body)
    }

    private func makePlayerProfilesResponse() -> ScaffoldingResponse {
        do {
            let data = try JSONEncoder().encode(players)
            return .ok(data)
        } catch {
            return .error("encode failed: \(error.localizedDescription)")
        }
    }

    private func handlePlayerPing(_ req: ScaffoldingRequest, from conn: NWConnection) -> ScaffoldingResponse {
        do {
            let profile = try JSONDecoder().decode(PlayerProfile.self, from: req.body)
            queue.async {
                self.connections[profile.machineId] = conn
                self.lastPing[profile.machineId] = Date()
                self.upsertPlayer(profile)
            }
            // 响应当前完整玩家列表
            return makePlayerProfilesResponse()
        } catch {
            return .error("invalid player_ping body: \(error.localizedDescription)",
                          code: .invalidRequest)
        }
    }

    // MARK: - Player management

    private func upsertPlayer(_ profile: PlayerProfile) {
        // 保留房主自己的 HOST 角色，不被访客覆盖
        var p = profile
        if p.machineId == hostProfile.machineId {
            p.kind = .host
        } else {
            p.kind = .guest
        }
        var changed = false
        if let idx = players.firstIndex(where: { $0.machineId == p.machineId }) {
            if players[idx] != p {
                players[idx] = p
                changed = true
            }
        } else {
            players.append(p)
            changed = true
            os_log("Player joined: %{public}@", log: log, type: .info, p.name)
        }
        if changed {
            broadcastPlayerList()
        }
    }

    private func removeConnection(_ conn: NWConnection) {
        queue.async {
            let leavingId = self.connections.first(where: { $0.value === conn })?.key
            if let id = leavingId {
                self.connections.removeValue(forKey: id)
                self.lastPing.removeValue(forKey: id)
                self.players.removeAll(where: { $0.machineId == id && $0.machineId != self.hostProfile.machineId })
                os_log("Player left: %{public}@", log: self.log, type: .info, id)
                DispatchQueue.main.async { self.broadcastPlayerList() }
            }
        }
    }

    /// 玩家列表变化时主动向所有活跃连接推送。
    private func broadcastPlayerList() {
        let snapshot = players
        guard !snapshot.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            let resp = ScaffoldingResponse.ok(data)
            let payload = resp.encode()
            for (_, conn) in connections {
                conn.send(content: payload, completion: .contentProcessed { _ in })
            }
        } catch {
            os_log("broadcastPlayerList encode failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.cleanupStalePlayers()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupStalePlayers() {
        let now = Date()
        let timeout: TimeInterval = 15
        var removed: [String] = []
        for (id, last) in lastPing where id != hostProfile.machineId {
            if now.timeIntervalSince(last) > timeout {
                removed.append(id)
            }
        }
        guard !removed.isEmpty else { return }
        for id in removed {
            connections[id]?.cancel()
            connections.removeValue(forKey: id)
            lastPing.removeValue(forKey: id)
        }
        DispatchQueue.main.async {
            self.players.removeAll(where: { removed.contains($0.machineId) })
            self.broadcastPlayerList()
        }
    }

    // MARK: - Send

    private func send(_ response: ScaffoldingResponse, to conn: NWConnection) {
        let payload = response.encode()
        conn.send(content: payload, completion: .contentProcessed { error in
            if let error = error {
                os_log("Send failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
            }
        })
    }
}
